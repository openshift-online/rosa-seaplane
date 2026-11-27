# Thanos Metrics Infrastructure

**Last Updated**: 2026-03-27

## Summary

Thanos is deployed on regional clusters to ingest metrics from management clusters and store them
long-term in S3. Two separate ArgoCD applications are deployed: `thanos-operator` installs the
upstream operator (CRDs, Deployment, RBAC) via an OCI Helm subchart, and `thanos` deploys all
platform-specific resources (Thanos CRs, S3 secret, Pod Identity SA, ALB TGB). The operator image
uses the Red Hat RHOBS Konflux build (UBI9, Clair/ClamAV/Snyk/Coverity) to meet FedRAMP image
requirements.

## Context

**Problem**: Regional clusters need to collect metrics from multiple management clusters across AWS
accounts and retain them durably for compliance and operational visibility. The initial implementation
maintained the operator CRDs, Deployment, and RBAC locally — these drifted silently from upstream,
causing ArgoCD ServerSideApply failures when field names changed.

**Constraints**:

- FIPS-compliant AWS endpoints (FedRAMP)
- EKS Pod Identity for IAM auth — no static credentials
- KMS encryption at rest
- UBI9 base images with automated security scanning (Clair, ClamAV, Snyk)
- Minimize locally-maintained operator code

**Assumptions**: Management clusters send metrics via Prometheus `remote_write`. Self-managed Karpenter is the compute strategy. Raw retention is 90d; downsampled retention is 180d (5m) and 365d (1h).

## Decision

Deploy the operator and the platform resources as **two independent ArgoCD applications** picked up
directly by the ApplicationSet. `thanos-operator` is a thin wrapper chart with a single OCI subchart
dependency on the upstream operator. `thanos` renders only platform-specific resources (Thanos CRs,
S3 secret, Pod Identity SA, ALB TGB). IAM is split into two least-privilege roles: a write role for
the Receiver ingester and Compactor, and a read-only role for the Store Gateway.

## Alternatives

| Option                                   | Rejected because                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| Self-maintained CRDs (previous approach) | 5 CRD files (~38k lines) drifted silently; schema errors only caught at sync time |
| App-of-apps (nested `Application` CR)    | Adds an ArgoCD sync cycle dependency; two flat apps achieve the same separation   |
| Bitnami Helm chart                       | No operator reconciliation; no FedRAMP-compliant image                            |
| Direct manifests                         | Highest maintenance burden; no automatic drift recovery                           |

## Consequences

**Positive**

- CRDs, Deployment, and RBAC are no longer maintained here — upgrading = one OCI chart version bump
- RHOBS UBI9 image meets FedRAMP base image and scanning requirements
- KMS key ARN flows automatically from Terraform → ECS task definition environment (no bootstrap script overrides)
- `SkipDryRunOnMissingResource=true` prevents sync failures during initial deploy before CRDs exist
- Store Gateway is restricted to read-only S3 access; write permissions are isolated to ingester and compactor

**Negative**

- Initial deploy needs one ArgoCD self-healing retry (CRDs install in cycle 1, CRs apply in cycle 2)
- Upstream OCI chart version must be manually bumped to consume upstream fixes
- RHOBS image tags are commit hashes, not semantic versions

## Security

- FIPS S3 endpoint auto-selected for all `us-*` regions (`s3-fips.<region>.amazonaws.com`); standard
  endpoint for non-US — no manual flag needed
- IAM role ARN partition is derived from region: `aws-us-gov` for `us-gov-*`, `aws` otherwise
- SSE-KMS encryption for all S3 writes
- EKS Pod Identity — no static credentials anywhere
- **Two IAM roles** enforce least-privilege by component:
  - Write role (ingester, compactor): `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`
  - Read-only role (store): `s3:GetObject`, `kms:Decrypt`, `kms:DescribeKey` — no write or key-generation permissions

## Implementation

### How the Two Upstream Repos Are Used

```
thanos-community/thanos-operator  →  OCI Helm subchart pulled by thanos-operator app
                                      (CRDs, operator Deployment, RBAC)
rhobs/rhobs-konflux-thanos-operator → Container image injected as values override
                                      (same code, UBI9 base, Konflux scanning)
```

### ArgoCD Apps

Two ArgoCD applications are deployed to the regional cluster for Thanos:

| App (`argocd/config/regional-cluster/`) | Purpose                                                                     |
| --------------------------------------- | --------------------------------------------------------------------------- |
| `thanos-operator/`                      | Installs the Thanos operator (CRDs, Deployment, RBAC) via OCI Helm subchart |
| `thanos/`                               | Installs all platform-specific Thanos resources (CRs, secret, SA, TGB)      |

Both applications are picked up directly by the root ApplicationSet — there is no nesting.

### Templates in `thanos/`

All templates are platform-specific resources not provided by either upstream repo:

| Template                       | Renders                        | Why here                                              |
| ------------------------------ | ------------------------------ | ----------------------------------------------------- |
| `receiver.yaml`                | `ThanosReceive` CR             | Platform config (replicas, storage, region labels)    |
| `query.yaml`                   | `ThanosQuery` CR               | Platform config (replicas, frontend)                  |
| `store.yaml`                   | `ThanosStore` CR               | Platform config (replicas, storage)                   |
| `compact.yaml`                 | `ThanosCompact` CR             | Platform config (retention, storage)                  |
| `ruler.yaml`                   | `ThanosRuler` CR               | Rule evaluation against Thanos Query, alerting        |
| `objstore-secret.yaml`         | `Secret` (`objstore.yml`)      | S3/KMS config derived from global values              |
| `serviceaccount.yaml`          | `ServiceAccount`               | Pod Identity annotation — AWS-specific                |
| `targetgroupbinding.yaml`      | `TargetGroupBinding`           | ALB wiring — AWS-specific                             |
| `pull-secret.yaml`             | `ExternalSecret` → `Secret`    | Creates the registry pull-secret `Secret` via ESO     |
| `operand-serviceaccounts.yaml` | `ServiceAccount`s for operands | `imagePullSecrets` configuration for Thanos workloads |
| `_helpers.tpl`                 | Shared label/annotation macros | `SkipDryRunOnMissingResource`, Helm release labels    |

### Components

| Component              | Purpose                                             | Replicas |
| ---------------------- | --------------------------------------------------- | -------- |
| ThanosReceive Router   | Distributes incoming `remote_write` requests        | 1        |
| ThanosReceive Ingester | Stores metrics locally, ships 2h blocks to S3       | 1        |
| ThanosQuery            | Queries Receiver (live) and Store (historical)      | 2        |
| ThanosQuery Frontend   | Caches and splits queries                           | 1        |
| ThanosStore            | Serves historical blocks from S3                    | 2        |
| ThanosCompact          | Compacts and downsamples S3 blocks                  | 1        |
| ThanosRuler            | Evaluates alerting/recording rules via Thanos Query | 2        |

### Terraform Resources (`terraform/modules/thanos-infrastructure/`)

- `aws_s3_bucket` — `${cluster_id}-thanos-metrics-${account_id}`, versioning + SSE-KMS + lifecycle policies
- `aws_kms_key` — dedicated key for Thanos S3 encryption
- `aws_iam_role.thanos_receiver` — write role for ingester and compactor; KMS key generation included
- `aws_iam_role.thanos_store` — read-only role for Store Gateway; no write or key-generation permissions
- `aws_eks_pod_identity_association` — one per operator-managed service account, wired to the appropriate role (includes Ruler, which uses the write role)

### Key Pinned Values

| Setting            | Value                                                                     |
| ------------------ | ------------------------------------------------------------------------- |
| RHOBS image tag    | `f83fea08f2a9167647cd8a9fd72f682c638c3cbb`                                |
| RHOBS image digest | `sha256:c4512873aecd1c8ca8c83d6ddad8fa9e55d4c0924cf9453d97280845d7934830` |
| StorageClass       | `gp3` (shared chart, `ebs.csi.eks.amazonaws.com`, `WaitForFirstConsumer`) |

## Related

- [Metrics Platform Overview](monitoring-platform.md) — end-to-end metrics architecture
- [MC Metrics Pipeline via Remote Write](mc-metrics-remote-write.md) — cross-account ingestion path
- [thanos-community/thanos-operator](https://github.com/thanos-community/thanos-operator)
- [rhobs/rhobs-konflux-thanos-operator](https://github.com/rhobs/rhobs-konflux-thanos-operator)
- [Thanos Documentation](https://thanos.io/tip/thanos/getting-started.md/)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
