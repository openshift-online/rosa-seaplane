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
from SSM into the `pull-secret` Secret in each HCP namespace. ESO re-syncs this
every hour.

When ecr-creds-sync is active, it overwrites that Secret with ECR credentials.
ESO's next sync would overwrite ecr-creds-sync's token with the SSM content.
To avoid this, the SSM pull secret at `/infra/pull-secret` must be updated to
include ECR credentials alongside the existing `quay.io` and
`registry.redhat.io` entries, so that ESO and ecr-creds-sync converge on
compatible content.

Alternatively, the ExternalSecret refresh interval can be extended beyond the
ECR token lifetime (12 hours) in environments where the SSM pull secret does
not carry ECR credentials.

## Configuration

### Step 1 — seaplane-operator: image source redirect

The seaplane-operator reads four environment variables at startup. Set all four
together or none at all; partial configuration causes the operator to exit.

| Variable                      | Description                                       |
| ----------------------------- | ------------------------------------------------- |
| `ECR_MIRROR_REGISTRY_ACCOUNT` | AWS account ID of the ECR registry                |
| `ECR_MIRROR_REGISTRY_REGION`  | AWS region of the ECR registry                    |
| `ECR_MIRROR_REPOSITORY`       | ECR repository name                               |
| `ECR_MIRROR_SOURCES`          | Comma-separated source registry paths to redirect |

Wire these via the seaplane-operator Helm values in
`argocd/config/regional-cluster/platform-api/values.yaml` or via the
environment-specific ArgoCD values overlay.

See [docs/operator/configuration.md](../seaplane-api/docs/operator/configuration.md)
in `rosa-seaplane-api` for the full operator configuration reference.

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
```

**What this enables:**

- Terraform (`enable_ecr_creds_sync: true`) provisions the IAM role and EKS Pod
  Identity association in the MC account so the controller can call
  `ecr:GetAuthorizationToken` without storing AWS credentials.
- The ArgoCD application deploys the `ecr-creds-sync` Helm chart into the
  `hypershift` namespace on the MC.

**IAM permissions required on the MC node role (Terraform-managed):**

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

### Integration (int0)

```yaml
# config/integration/defaults.yaml
management_cluster_defaults:
  enable_ecr_creds_sync: true

applications:
  management-cluster:
    ecrCredsSync:
      ecrRepository: "<ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/<repository>"
      awsRegion: "<ecr-region>"
    eksNodePool:
      ecrMirror:
        mirrors:
          - sourcePrefix: source-registry.example.com/org/component-images
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
          - sourcePrefix: source-registry.example.com/org/release-image
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
```

### Stage

```yaml
# config/stage/defaults.yaml
management_cluster_defaults:
  enable_ecr_creds_sync: true

applications:
  management-cluster:
    ecrCredsSync:
      ecrRepository: "<ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/<repository>"
      awsRegion: "<ecr-region>"
    eksNodePool:
      ecrMirror:
        mirrors:
          - sourcePrefix: source-registry.example.com/org/component-images
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
          - sourcePrefix: source-registry.example.com/org/release-image
            registryUri: <ecr-account>.dkr.ecr.<ecr-region>.amazonaws.com/org/component-images
```

After editing, regenerate rendered files and commit both together:

```bash
uv run scripts/render.py
make pre-push
```

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
