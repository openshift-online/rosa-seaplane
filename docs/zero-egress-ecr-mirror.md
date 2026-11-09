# Zero-Egress ECR Image Mirror

Management clusters in zero-egress environments have no NAT Gateway or Internet
Gateway. HCP dataplane nodes therefore cannot pull OCP release images directly
from `quay.io`. This document describes how the platform redirects those image
pulls to a private ECR registry and keeps the registry credentials fresh.

## Architecture

Three components work together:

```
seaplane-operator (RC)
  └── sets HostedCluster.spec.imageContentSources
        └── HyperShift generates /etc/containers/registries.conf on nodes
              └── CRI-O redirects dataplane pulls to ECR mirror

ecr-creds-sync (MC)
  └── calls ecr:GetAuthorizationToken via Pod Identity
        └── writes pull-secret in each HCP namespace
              └── ignition server embeds credentials in node boot config

Karpenter EC2NodeClass userData (MC)
  └── writes /etc/containers/registries.conf.d/ecr-mirror.conf at node boot
        └── CRI-O on MC nodes redirects HCP control plane pulls to ECR mirror
```

**imageContentSources** tells CRI-O on each dataplane node which source
registries to redirect to the ECR mirror. This is set once at cluster creation
and stored in the HostedCluster object on the MC.

**ecr-creds-sync** refreshes the ECR authorization token every two hours (ECR
tokens are valid for 12 hours). It writes the token as the `pull-secret` in
each HostedCluster namespace on the MC. HyperShift's ignition server uses this
secret when generating the boot configuration for new nodes.

**EC2NodeClass userData** injects a CRI-O drop-in configuration on each MC
worker node at boot time, redirecting pulls for HCP control plane component
images from `quay.io` to the ECR mirror. This covers images pulled by the MC
nodes themselves (HCP pods), as opposed to dataplane nodes which are covered
by imageContentSources. MC nodes authenticate to ECR via their IAM instance
profile — no token refresh is needed.

## Coordination with External Secrets Operator

The seaplane-operator renders an ExternalSecret that syncs `/infra/pull-secret`
from SSM into a Secret in each HCP namespace. ESO re-syncs this every hour.

When `ECR_MIRROR_BASE_SECRET_NAME` is set (e.g. `base-pull-secret`), the
ExternalSecret targets that name instead of `pull-secret`. This separates the
two writers:

- **ESO** writes `base-pull-secret` (SSM content: `quay.io`,
  `registry.redhat.io` credentials)
- **ecr-creds-sync** reads `base-pull-secret`, merges the ECR authorization
  token into it, and writes the combined result to `pull-secret`

HyperShift reads `pull-secret` for ignition config — it always gets both the
SSM credentials and a fresh ECR token, with no overwrite conflict between ESO
and ecr-creds-sync.

Configure this via `ecrCredsSync.sourceSecrets` in the ecr-creds-sync chart
(set to the same name as `ECR_MIRROR_BASE_SECRET_NAME`) and ensure the
seaplane-operator has `ECR_MIRROR_BASE_SECRET_NAME` set to match.

## Configuration

### Step 1 — seaplane-operator: image source redirect

The seaplane-operator reads five environment variables at startup. Set all five
together or none at all; partial configuration causes the operator to exit.

| Variable                      | Description                                       |
| ----------------------------- | ------------------------------------------------- |
| `ECR_MIRROR_REGISTRY_ACCOUNT` | AWS account ID of the ECR registry                |
| `ECR_MIRROR_REGISTRY_REGION`  | AWS region of the ECR registry                    |
| `ECR_MIRROR_REPOSITORY`       | ECR repository name                               |
| `ECR_MIRROR_SOURCES`          | Comma-separated source registry paths to redirect |
| `ECR_MIRROR_BASE_SECRET_NAME` | Base pull-secret name (must not be `pull-secret`) |

**These values are sourced from SSM, not from git.** They are provisioned as SSM
parameters in the RC account by `rosa-seaplane-internal` and read by the RC
bootstrap script, which threads them into ArgoCD cluster secret annotations. The
ApplicationSet template forwards the annotations to the seaplane-operator chart
as `ECR_MIRROR_*` env vars.

**To provision the SSM parameters**, set the four locals in
`infra/environments/<env>/account-config/rc/defaults.hcl` in
`rosa-seaplane-internal` and apply:

```hcl
# infra/environments/<env>/account-config/rc/defaults.hcl
locals {
  ecr_mirror_region           = "<ecr-region>"
  ecr_mirror_repository       = "<repository>"
  ecr_mirror_sources          = "<source1>,<source2>"
  ecr_mirror_base_secret_name = "base-pull-secret"
}
```

```bash
make apply-account-config ENV=<env>
```

For per-region overrides, create
`infra/environments/<env>/account-config/rc/<region>.hcl` with the same locals.
Regions without a file inherit from `defaults.hcl`.

The ECR registry account ID (`ECR_MIRROR_REGISTRY_ACCOUNT`) is sourced from the
existing `/infra/image-registry/account_id` SSM parameter, which is provisioned
separately by the shared ECR account onboarding.

**To activate the mirror in rosa-seaplane**, set only the boolean opt-in in
`config/<env>/defaults.yaml` and re-render:

```yaml
applications:
  regional-cluster:
    seaplane:
      ecrMirror:
        enabled: true
```

```bash
uv run scripts/render.py
```

The re-bootstrap (or next scheduled bootstrap pipeline run) reads the SSM values
and updates the ArgoCD cluster secret annotations. No ECR config values live in
git.

See `docs/operator/configuration.md` in `rosa-seaplane-api` for the full
operator configuration reference.

### Step 2 — ecr-creds-sync: credential refresh on the MC

**Enable via config** (`config/<env>/defaults.yaml`):

```yaml
management_cluster_defaults:
  enable_ecr_creds_sync: true

applications:
  management-cluster:
    ecrCredsSync:
      ecrRepository: "<account>.dkr.ecr.<region>.amazonaws.com/<repository>"
      awsRegion: "<region>"
      # Must match applications.regional-cluster.seaplane.ecrMirror.baseSecretName
      sourceSecrets: "base-pull-secret"
```

**What this enables:**

- Terraform (`enable_ecr_creds_sync: true`) provisions the IAM role and EKS Pod
  Identity association in the MC account so the controller can call
  `ecr:GetAuthorizationToken` without storing AWS credentials.
- The ArgoCD application deploys the `ecr-creds-sync` Helm chart into the
  `hypershift` namespace on the MC.

**IAM permissions required on the ecr-creds-sync Pod Identity role (Terraform-managed):**

```json
{
  "Effect": "Allow",
  "Action": "ecr:GetAuthorizationToken",
  "Resource": "*"
}
```

**ECR resource policy required (rosa-srep-zero-egress):**

The zero-egress ECR resource policy must include the MC accounts' OU path in
`hyperfleet_pull_org_paths` so that nodes can pull images. The ecr-creds-sync
controller only needs `ecr:GetAuthorizationToken`, which is an IAM action
evaluated in the caller's own account and does not require an ECR resource
policy.

### Step 3 — EC2NodeClass userData: MC control plane image redirect

The Karpenter EC2NodeClass for MC worker nodes can be configured to redirect
HCP control plane image pulls from `quay.io` to ECR at node boot. This applies
only to nodes booted with a custom AMI (rhel-bootc/CRI-O); the default
Bottlerocket path is not affected.

**Enable via config** (`config/<env>/defaults.yaml`) alongside Step 2:

```yaml
applications:
  management-cluster:
    eksNodePool:
      ecrMirror:
        mirrors:
          - sourcePrefix: source-registry.example.com/org/component-images
            registryUri: <account>.dkr.ecr.<region>.amazonaws.com/org/component-images
          - sourcePrefix: source-registry.example.com/org/release-image
            registryUri: <account>.dkr.ecr.<region>.amazonaws.com/org/component-images
```

The `enabled` flag is derived automatically from
`management_cluster_defaults.enable_ecr_creds_sync` — no separate flag needed.

Each `mirrors` entry pairs a `sourcePrefix` (the exact source repository URI)
with a `registryUri` (the ECR repository URI). Both must be at the same path
depth: CRI-O appends the remainder of the image reference after the matched
prefix to the mirror URI, so a mismatch in depth produces an incorrect path.

**What this does:**

At node boot, a shellscript in the MIME multipart userData writes
`/etc/containers/registries.conf.d/ecr-mirror.conf` with a CRI-O mirror entry,
then restarts CRI-O. New MC nodes that Karpenter provisions after this change
pick up the config automatically. Existing nodes require replacement (Karpenter
rolling replacement via node disruption).

**IAM for MC nodes:**

MC Karpenter nodes already have `AmazonEC2ContainerRegistryPullOnly` for
same-account ECR. Cross-account access to the zero-egress ECR is covered by the
ECR resource policy in `rosa-srep-zero-egress` (the MC account OU is listed in
`hyperfleet_pull_org_paths`). No additional IAM policy changes are needed.

## Enabling per environment

Enabling the mirror requires changes in two repositories and re-bootstrap.

### Step A — provision SSM parameters (`rosa-seaplane-internal`)

Set the ECR mirror locals in
`infra/environments/<env>/account-config/rc/defaults.hcl` and apply:

```hcl
# infra/environments/int/account-config/rc/defaults.hcl  (or stage/)
locals {
  ecr_mirror_region           = "<ecr-region>"
  ecr_mirror_repository       = "<repository>"
  ecr_mirror_sources          = "<source1>,<source2>"
  ecr_mirror_base_secret_name = "base-pull-secret"
}
```

```bash
make apply-account-config ENV=int   # or stage
```

For per-region values, create `account-config/rc/<region>.hcl` with the locals
that differ from the defaults.

### Step B — activate in config (`rosa-seaplane`)

```yaml
# config/integration/defaults.yaml  (or stage/)
management_cluster_defaults:
  enable_ecr_creds_sync: true

applications:
  management-cluster:
    ecrCredsSync:
      ecrRepository: "<ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/<repository>"
      awsRegion: "<ecr-region>"
      sourceSecrets: "base-pull-secret"
    eksNodePool:
      ecrMirror:
        mirrors:
          - sourcePrefix: source-registry.example.com/org/component-images
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
          - sourcePrefix: source-registry.example.com/org/release-image
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
  regional-cluster:
    seaplane:
      ecrMirror:
        enabled: true # all other fields come from SSM — do not set them here
```

```bash
uv run scripts/render.py
make pre-push
```

The seaplane-operator values (`registryAccount`, `registryRegion`, `repository`,
`sources`, `baseSecretName`) are sourced from the SSM parameters provisioned in
Step A and are not committed to git.

### Step C — re-bootstrap the RC

Re-run the RC bootstrap pipeline (or wait for the next scheduled run). The
bootstrap script reads the new SSM parameters and updates the ArgoCD cluster
secret annotations. ArgoCD then syncs the new values to the seaplane-operator.

## Token refresh behaviour

ecr-creds-sync mints one ECR token shared across all HostedClusters on the MC.
The token is cached in memory for the configured `refreshAfter` interval
(default `2h`). After each reconcile the controller requeues itself after
`refreshAfter`, so credentials are refreshed proactively rather than on demand.

A process restart clears the in-memory cache and causes a fresh token to be
minted on the first reconcile after restart.

## Related repositories

| Repository                     | Role                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------ |
| `rosa-seaplane-api`            | seaplane-operator sets `imageContentSources` on each HostedCluster                   |
| `rosa-seaplane-ecr-creds-sync` | Controller source — Reconciler, token cache, dockerconfig generation                 |
| `rosa-srep-zero-egress`        | ECR mirror infrastructure — root/replica ECR accounts, resource policies, mirror job |
