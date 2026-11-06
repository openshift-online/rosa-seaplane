# Configure Platform API authorization

This repository delivers the Platform API's resource authorization bundle and
optional management configuration. Canonical API references:

- [Authorization](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/README.md)
  defines runtime behavior, bundle format, actions, labels, and metrics.
- [Management](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/management.md)
  defines management HTTP, delegation, revisions, and writer guidance.
- [Storage contract](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/storage-contract.md)
  defines storage guarantees and infrastructure gates.

This repository retains ownership of storage provisioning, Terraform state, IAM,
and configuration delivery. AWS provisioning has not started.

Resource authorization still uses the startup bundle and runtime account allowlist,
not management's DynamoDB policies, until ROSAENG-67498. Management is disabled by
default. Management bootstrap grants no resource access.

Resource authorization is mandatory and denies by default. Startup-bundle
enrollment alone grants nothing.

## Prerequisite: gateway-only access

The API trusts the `X-Amz-Account-Id` and `X-Amz-Caller-Arn` headers without
authenticating who sent them. The chart's ClusterIP Service exposes API port 8000,
which does not check those headers. Any caller that reaches the pod directly can
impersonate an enrolled identity. Restrict access to the API
Gateway path before shared rollout. This is unproven (ROSAENG-67493).

## Set the bundle

Set `applications.regional-cluster.platformApi.authz.config` in
`config/defaults.yaml` for the default shared by all environments. Use
`config/<environment>/defaults.yaml` or `config/<environment>/<region>.yaml` for
environment- or region-specific overrides. The value is the complete bundle as a
YAML string. An override replaces the whole bundle; nothing is merged.

```yaml
applications:
  regional-cluster:
    platformApi:
      authz:
        config: |
          formatVersion: 1
          registeredAccounts: []
          policies: []
          attachments: []
```

That bundle denies everything.

## Bootstrap a policy administrator

Set `applications.regional-cluster.platformApi.authz.managementConfig` in source
configuration. Replace these illustrative table names and identities with approved
values. They are not deployed resources:

```yaml
applications:
  regional-cluster:
    platformApi:
      authz:
        managementConfig: |
          formatVersion: 1
          policyTable: example-authz-policies
          globalTable: example-authz-global-attachments
          regionalTable: example-authz-regional-attachments
          accounts:
            "111111111111":
              writerRegion: us-east-1
              administratorARNs:
                - arn:aws:iam::111111111111:role/customer-policy-admin
```

Administrators manage only their configured account. Role ARNs cover assumed-role
sessions. No Red Hat linking or `/accounts` enrollment is required for management.
This configuration does not change customer resource onboarding through
[the runtime account allowlist](#use-the-legacy-account-allowlist).

Before enabling management, provide:

- An API image implementing `AUTHZ_MANAGEMENT_CONFIG_FILE` and management routes.
- Approved policy/global-attachment replicas and a local regional-attachment table
  matching the storage contract. The chart provisions no tables, IAM, or Pod
  Identity association. That remains separate ROSAENG-67496 work.
- Workload SDK credentials with table-scoped CRUD, query, batch-read, and
  transactional-write permissions, network access, and required KMS permissions.
- An agreed writer per account and authenticated gateway access for administrators.
  Global writes must use that writer. Follow the API management contract for
  wrong-writer retries, local-commit receipts, and asynchronous replication limits.
  Do not fail over global writes to another region.

Ownership, revisions, and regions are server-assigned. Updates and deletes require
`If-Match`; stale revisions return 409. Follow the
[management contract](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/management.md)
for revision preconditions and write requests.

For ephemeral environments, merge the override into `.ephemeral-env/defaults.yaml`.
Preserve unrelated overrides. These commands perform a rollout and authenticated
reads, not local validation:

```sh
make ephemeral-resync ID=<id>
AWS_PROFILE=customer-policy-admin awscurl --service execute-api --region us-east-1 \
  "$API_URL/api/v0/authz/policies"
AWS_PROFILE=customer-policy-admin awscurl --service execute-api --region us-east-1 \
  "$API_URL/api/v0/authz/attachments?scope=regional"
```

Reads are repeatable and return empty lists for an empty store. They need no
resource grant. `/authz/check` remains absent.

Omitted, empty, or Helm `null` management config disables the routes and emits no
management file or environment variable. Non-string values fail Helm rendering.
Nonempty strings receive basic YAML syntax/object checks, not full semantic
validation. Go's `LoadManagementConfig` and `checkManagementConfig` validate the
complete contract at startup. Delivery does not expand resource markers or
execute Helm templates inside the management string.

The chart adds `management.yaml` beside `config.yaml` in ConfigMap `authz-config`.
Both use the read-only `/etc/platform-api/authz` mount and `checksum/authz-config`.
It sets `AUTHZ_CONFIG_FILE` and, when enabled, `AUTHZ_MANAGEMENT_CONFIG_FILE`.
Separate API loaders read the files at startup. Either change requires a rollout.

## Enrollment and management clusters

`config/defaults.yaml` holds the one bundle every environment uses. It enrolls
the RC account and grants the identities behind `rrp-rc` (the child-admin role,
`aws.child_admin_role_name`, and CI's `e2e` user) `AllActions` on the RC
account's own resources, except requests tagged `authz-deny-probe`. It names no
account ID. Customer accounts get no grants; allowlist them (see below). The e2e
allowlists its customer account before the ROSA CLI tests.

- `@@AWS_ACCOUNT_ID@@` and `@@AWS_REGION@@` resolve in Helm from
  `global.aws_account_id` and `global.aws_region`, because stable environments
  only know the account at deploy time. Helm fails if a used marker has no valid
  value.
- ManagementClusters are not authorized through the bundle. platform-api
  registers each entry of `MANAGEMENT_CLUSTERS` (`id:account`, from the RC's
  `management_clusters`, delivered as `global.management_clusters`) on startup.
  Existing entries are kept. The RC pipeline waits for the RC API
  (`scripts/buildspec/wait-for-regional-api.sh`) before provisioning completes.

## Override the bundle in an ephemeral environment

To test other grants, copy the example override before provisioning or
resyncing. It replaces the whole bundle: it repeats the default RC grants and adds a
`ReadOnly` role (`dev-readers`, replace it with yours) in the RC account. It names
no account ID; `@@AWS_ACCOUNT_ID@@` resolves to the RC account. Merge any
existing overrides first.

```sh
mkdir -p .ephemeral-env
cp -n docs/examples/authz-dev/*.yaml .ephemeral-env/
make ephemeral-resync ID=<id>
```

## Use the legacy account allowlist

The temporary allowlist admits an account and gives it full access to its own
resources, without a bundle change or rollout. It lives in seaplane-db and will be
replaced by DynamoDB policy storage. Only callers from the RC's own account may
change it (`AWS_ACCOUNT_ID`, from `global.aws_account_id`). It grants no management
authority.

Ephemeral environments:

```sh
make ephemeral-post-account-shell ACCOUNT_ID=<12-digit-id> [ID=<env-id>]
make ephemeral-delete-account-shell ACCOUNT_ID=<12-digit-id> [ID=<env-id>]
```

Integration and stage, with credentials for the RC account:

```sh
awscurl --service execute-api -X POST -H 'Content-Type: application/json' \
  -d '{"accountId":"<12-digit-id>"}' "$API_URL/api/v0/accounts"
awscurl --service execute-api -X DELETE "$API_URL/api/v0/accounts/<12-digit-id>"
```

Both calls are idempotent and return 204. Revocation takes effect on the next
request. Platform API logs record each change as `account enrolled` or
`account unenrolled` with the caller ARN.

## Customer label permissions

Label routes, actions, and validation are defined in the API document. `ReadOnly`
includes `ListLabelsForResource`; `AllActions` includes `LabelAdmin`. Grant
label administration only to callers trusted to change authorization inputs.

## Render and roll out

```sh
uv run scripts/render.py
helm template platform-api argocd/config/regional-cluster/platform-api \
  --set global.aws_region=us-east-1 --set-string global.aws_account_id="$RC_ACCOUNT_ID" \
  -f deploy/ephemeral/us-east-1/argocd-values-regional-cluster.yaml
```

- The chart renders ConfigMap `authz-config`, mounts it read-only at
  `/etc/platform-api/authz/config.yaml`, and sets `AUTHZ_CONFIG_FILE`.
- Pod annotation `checksum/authz-config` hashes the ConfigMap, so any bundle
  change rolls the Deployment.
- The API reads the bundle only at startup. An invalid bundle fails startup. Old
  pods keep old permissions until replaced, so revocation is not instantaneous.
  Logs carry `bundle_hash` (SHA-256 of the loaded bundle) to identify it.
- The `platform-api` and `seaplane-operator` images must be pinned to the same
  API commit. Both run FleetDB migrations at startup.
- Bundles naming actions or a schema namespace an older API lacks fail its
  startup. Change the image pin in the same commit as such a bundle, and never
  deploy a more permissive interim bundle.

## Metrics

The Service exposes port `metrics` (9090) and the ServiceMonitor scrapes
`/metrics`. See the canonical
[authorization reference](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/authz/README.md)
for metric names and labels.

## Tests

```sh
uv run scripts/test_render.py
```

Helm-backed tests require Helm on `PATH`.
