# Configure Platform API authorization

This repo provisions retained DynamoDB tables and API IAM, delivers table names,
and seeds the first grants directly into DynamoDB from CI. See the API
repo's [runtime](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/README.md),
[management](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/management.md),
and [storage](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/storage-contract.md)
contracts for permission and API behavior.

## Prepare the deployment

1. Verify gateway-only access. The API trusts `X-Amz-Account-Id` and
   `X-Amz-Caller-Arn`; direct access to port 8000 allows impersonation. ClusterIP
   does not enforce this boundary. Gateway isolation remains unverified.
2. Approve the region, retained backend bucket/key, three table names, account IDs,
   and retention/recovery owner.
3. Retained tables carry `platform-janitor/lifecycle=ignore`, which both janitor
   configs skip. Other cleanup systems need the same exclusion.
4. Provision `terraform/config/authz-storage` under separate retained state with
   `aws_region` and `table_names` keys `policies`, `global`, and `regional`.
   Keep the backend key stable across RC replacement and outside RC/MC destroy.
   Integration, stage, and ephemeral environments skip this step:
   `regional_cluster.enable_ephemeral_authz_tables` makes the RC create unretained
   `<deployment_name>-authz-*` tables, destroyed with it. CI reseeds their grants.
5. Set these source values in `config/<environment>/defaults.yaml` or the region
   override. For ephemeral environments, use `.ephemeral-env/defaults.yaml`.
   - `regional_cluster.authz_tables` only if the provisioned tables differ from the
     default `<deployment_name>-authz-{policies,global,regional}`.
   - `applications.regional-cluster.platformApi.app.image`, pointing to a built,
     available API image that reads `AUTHZ_*_TABLE`, and
     `seaplane.source.targetRevision` in the platform-api wrapper chart, pointing to
     the API revision whose chart sets them.
     Use a compatible operator image. Configured image pins remain unverified.
6. Render and inspect before deployment:

   ```sh
   uv run scripts/render.py
   helm template platform-api argocd/config/regional-cluster/platform-api \
     --set global.aws_region=us-east-1 \
     -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
   ```

The API chart fails on missing table names. The API validates them at startup.

## Storage and runtime identity

The storage root creates three ordinary regional tables with string `pk`/`sk`
keys, on-demand billing, encryption, PITR, and deletion protection (module
`terraform/modules/authz-tables`). It creates no replicas. Intentional destruction
requires a separate approved procedure.

The RC root references those tables and associates `platform-api/platform-api-sa`
with permissions on their exact same-account, same-region ARNs. Allowed operations
are `GetItem`, `BatchGetItem`, `Query`, `PutItem`, `DeleteItem`, and
`ConditionCheckItem`. There is no scan, table administration, or operator role
expansion. Runtime IAM does not grant management API authority.

The wrapper forwards `regional_cluster.authz_tables` to the API chart
(rosa-seaplane-api `seaplane-api/charts`), which sets `AUTHZ_{POLICY,GLOBAL,REGIONAL}_TABLE`. Env changes roll the Deployment. ServiceMonitor scrapes
port 9090 at `/metrics`.

## Enroll AWS accounts

Every AWS account that calls the API must be enrolled, including the RC's own
account, which the e2e suites call from. With RC credentials, enroll an account:

```sh
awscurl --service execute-api -X POST -H 'Content-Type: application/json' \
  -d '{"accountId":"<approved-12-digit-account-id>"}' "$API_URL/api/v0/accounts"
```

Unenroll it:

```sh
awscurl --service execute-api -X DELETE \
  "$API_URL/api/v0/accounts/<approved-12-digit-account-id>"
```

Both return 204 idempotently. Enrollment grants no permissions.
Enrolling an account is separate from registering a ManagementCluster. Ephemeral wrappers
also provide `ephemeral-post-account-shell` and `ephemeral-delete-account-shell`.
ManagementClusters register separately through `MANAGEMENT_CLUSTERS`, delivered
as `global.management_clusters`; the RC pipeline waits for the API.

## Seed the first grants

Temporary pre-production seeding until SSO org-admin linking. After enrollment,
`ci/e2e-tests.sh` writes each account's first grants straight into the authz
tables with `rrp-rc`, before resource suites and cleanup; failure stops the run.
All tables live in the RC account, so one profile seeds the RC and customer
accounts. Tables are `<deployment_name>-authz-*` (`ZOA_DEPLOYMENT_NAME`, else the
region). Rows follow the API storage contract. For each account,
`rosa-seaplane-account-admin` gets:

- `e2e-policy-admin`: every authz management action.
- `e2e-all-actions`: every resource action except on `authz-deny-probe` tagged
  resources, so the monitoring suite can test denial.

Fixed IDs and `attribute_not_exists` make reruns a no-op. Changing a seeded grant
means deleting it through the management API first. Inspect the rows:

```sh
aws dynamodb query --table-name us-east-1-authz-policies \
  --key-condition-expression pk=:pk --expression-attribute-values '{":pk":{"S":"ACCOUNT#<account-id>"}}'
```

A developer account needs `rosa-seaplane-account-admin`, or any identity with
DynamoDB write access to the RC account's tables, to seed its own grants the same
way. A broken grant is repaired the same way: delete or overwrite its rows
directly.

## Verify locally and after deployment

```sh
ci/run-unit-tests.sh
make check-rendered-files helm-lint terraform-validate
```

Local tests do not establish deployment readiness. Verify gateway isolation,
negative IAM cases, allowed requests, denial, revocation, backend failure, metrics,
cross-account MC lifecycle/cleanup, and retained state across RC replacement.
