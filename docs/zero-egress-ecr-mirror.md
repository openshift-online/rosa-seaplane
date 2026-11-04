# Zero-Egress ECR Image Mirror

Management clusters in zero-egress environments have no NAT Gateway or Internet
Gateway. HCP dataplane nodes therefore cannot pull OCP release images directly
from `quay.io`. This document describes how the platform redirects those image
pulls to a private ECR registry and keeps the registry credentials fresh.

## Architecture

Two components work together:

```
seaplane-operator (RC)
  └── sets HostedCluster.spec.imageContentSources
        └── HyperShift generates /etc/containers/registries.conf on nodes
              └── CRI-O redirects pulls to ECR mirror

ecr-creds-sync (MC)
  └── calls ecr:GetAuthorizationToken via Pod Identity
        └── writes pull-secret in each HCP namespace
              └── ignition server embeds credentials in node boot config
```

**imageContentSources** tells CRI-O on each dataplane node which source
registries to redirect to the ECR mirror. This is set once at cluster creation
and stored in the HostedCluster object on the MC.

**ecr-creds-sync** refreshes the ECR authorization token every two hours (ECR
tokens are valid for 12 hours). It writes the token as the `pull-secret` in
each HostedCluster namespace on the MC. HyperShift's ignition server uses this
secret when generating the boot configuration for new nodes.

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
