# Configure Platform API authorization

This repo provisions the authz DynamoDB tables and API IAM, delivers table names,
and seeds the first grants directly into DynamoDB from CI. See the API
repo's [runtime](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/README.md),
[management](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/management.md),
and [storage](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/storage-contract.md)
contracts for permission and API behavior.

## Prepare the deployment

1. Verify gateway-only access. The API trusts `X-Amz-Account-Id` and
   `X-Amz-Caller-Arn`; direct access to port 8000 allows impersonation. ClusterIP
   does not enforce this boundary. Gateway isolation remains unverified.
2. Approve the region, three table names, account IDs, and retention/recovery
   owner.
3. The RC creates the tables. `regional_cluster.authz_dynamodb_deletion_protection`
   (default `true`) enables deletion protection, PITR, and the
   `platform-janitor/lifecycle=ignore` tag, which both janitor configs skip. Other
   cleanup systems need the same exclusion. Integration, stage, and ephemeral set
   it to `false`, so their tables are destroyed with the RC. CI reseeds their
   grants.
4. Set these source values in `config/<environment>/defaults.yaml` or the region
   override. For ephemeral environments, use `.ephemeral-env/defaults.yaml`.
   - `regional_cluster.authz_tables` only if the provisioned tables differ from the
     default `<deployment_name>-authz-{policies,global,regional}`.
   - `applications.regional-cluster.platformApi.app.image`, pointing to a built,
     available API image that reads `AUTHZ_*_TABLE`, and
     `seaplane.source.targetRevision` in the platform-api wrapper chart, pointing to
     the API revision whose chart sets them.
     Use a compatible operator image. Configured image pins remain unverified.
5. Render and inspect before deployment:

   ```sh
   uv run scripts/render.py
   helm template platform-api argocd/config/regional-cluster/platform-api \
     --set global.aws_region=us-east-1 \
     -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
   ```

The API chart fails on missing table names. The API validates them at startup.

## Storage and runtime identity

The RC root creates three ordinary regional tables with string `pk`/`sk` keys,
on-demand billing, and encryption (module `terraform/modules/authz-tables`), plus
PITR and deletion protection when enabled. It creates no replicas. Destroying
protected tables requires a separate approved procedure.

The RC root also associates `platform-api/platform-api-sa`
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
`ci/e2e-tests.sh` runs `scripts/dev/seed-authz-grants.sh`, which writes each
account's first grants straight into the authz tables with `rrp-rc`, before resource suites and cleanup; failure stops the run.
All tables live in the RC account, so one profile seeds the RC and customer
accounts. Tables are `<deployment_name>-authz-*` (`ZOA_DEPLOYMENT_NAME`, else the
region). Rows follow the API storage contract. For each account,
`rosa-seaplane-account-admin` gets:

- `e2e-policy-admin`: every authz management action.
- `e2e-all-actions`: every resource action except on `authz-deny-probe` tagged
  resources, so the monitoring suite can test denial.

To seed an enrolled account in an ephemeral environment:

```sh
make ephemeral-post-account-shell ACCOUNT_ID=<12-digit-id> [ID=<env-id>]
make ephemeral-seed-authz-shell ACCOUNT_ID=<12-digit-id> [ID=<env-id>]
```

Elsewhere, with `rrp-rc` credentials, run
`scripts/dev/seed-authz-grants.sh <account-id> <deployment_name>`.

Each policy and each attachment is a separate conditional write with a fixed ID,
so a rerun skips existing records and recreates deleted ones. Changing a seeded
grant means deleting it through the management API first. Inspect the rows:

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
cross-account MC lifecycle/cleanup, and deletion protection on production tables.
