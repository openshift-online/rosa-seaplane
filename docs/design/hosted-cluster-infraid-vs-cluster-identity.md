# ROSA Seaplane (v2): HostedCluster `infraID` vs Cluster Identity Divergence

**Last Updated Date**: 2026-11-19

**Tracking**: [ROSAENG-76285](https://redhat.atlassian.net/browse/ROSAENG-76285)

## Table of Contents

- [Summary](#summary)
- [Context](#context)
- [Current Design — ROSA Seaplane (v2)](#current-design--rosa-seaplane-v2)
  - [Why `infraID = path.Base(issuerURL)` is required](#why-infraid--pathbaseissuerurl-is-required)
  - [Resulting customer behavior](#resulting-customer-behavior)
- [Current Design — ROSA HCP (v1)](#current-design--rosa-hcp-v1)
- [v1 vs v2 Comparison](#v1-vs-v2-comparison)
- [Decision](#decision)
- [Consequences](#consequences)
- [Alternatives Considered](#alternatives-considered)
- [Implementation Reference](#implementation-reference)

## Summary

In ROSA Seaplane (v2) with managed OIDC, the HostedCluster's `spec.infraID` is deliberately **not** derived from the cluster name or UID. It is pinned to the OIDC configuration's ID (`path.Base(issuerURL)`) because HyperShift uses `InfraID` as the S3 object-key namespace for OIDC discovery documents in a fleet-wide shared bucket. This creates three distinct identifiers in play per cluster — cluster name, cluster UID, and infraID — and, combined with how subnet cluster tags are applied, caused ingress ELB creation failures (ROSAENG-76285). This document records the current v2 design, the resulting customer-visible behavior, and how it differs from ROSA HCP (v1).

## Context

- **Problem Statement**: The rosa CLI's `create network` command tagged cluster subnets with `kubernetes.io/cluster/<cluster.Name>=owned` via a CloudFormation stack-level tag. The AWS cloud-controller-manager (CCM) sets its `KubernetesClusterID` from `spec.infraID` and rejects any subnet carrying a `kubernetes.io/cluster/*` tag that does not match it. Since `<cluster.Name>` can never equal `<infraID>` in the managed-OIDC flow, no subnet was ever eligible for ELB creation, and hosted clusters stalled in `Partial` with `SyncLoadBalancerFailed`.
- **Constraints**:
  - HyperShift's HostedCluster controller hard-codes the OIDC S3 object key as `InfraID + path` (see [Why `infraID = path.Base(issuerURL)` is required](#why-infraid--pathbaseissuerurl-is-required)).
  - All clusters in the fleet share one operator-scoped OIDC bucket; the only per-cluster namespacing is the `InfraID` key prefix.
  - Seaplane's `OidcConfig` has a customer-chosen, **immutable** `spec.issuerUrl` of the form `https://<oidc-domain>/<oidc-id>`.
  - CCM's scoped IAM policy intentionally lacks `iam:CreateServiceLinkedRole`, matching ROSA.
- **Assumptions**:
  - The bucket/CDN front maps the issuer URL path directly to the S3 object key — no path rewriting.
  - An `OidcConfig` (and hence its issuer-URL suffix) is reusable after deletion.

## Current Design — ROSA Seaplane (v2)

Three identifiers coexist per cluster:

| Identifier             | Example             | Where used                                                                                             |
| ---------------------- | ------------------- | ------------------------------------------------------------------------------------------------------ |
| `cluster.Name`         | `cbussehcp`         | Subnet/VPC tags ( rosa CLI, historically), customer-facing                                             |
| `cluster.UID`          | `831005a8-576a-...` | HC `resourceTags`, namespace, labels                                                                   |
| `path.Base(issuerURL)` | `005fcb8b...`       | `spec.infraID` for managed OIDC (set in `seaplane-operator/internal/render/cluster.go`, ROSAENG-74281) |

### Why `infraID = path.Base(issuerURL)` is required

1. The HyperShift HostedCluster controller hard-codes the S3 object key as `InfraID + path` (`hostedcluster_controller.go`, `reconcileAWSOIDCDocuments`, ~line 5391), where the generated paths are `/.well-known/openid-configuration` and `/openid/v1/jwks`. GCP is identical (`gcp_oidc.go:73`).
2. All clusters in the fleet share a single bucket (operator-scoped `--oidc-storage-provider-s3-bucket-name`); the only per-cluster namespacing is the `InfraID` prefix of the object key.
3. The issuer URL's path **is** the S3 key. The bucket/CDN front serves `https://<oidc-domain>/<oidc-id>/.well-known/openid-configuration` from `s3://<bucket>/<oidc-id>/.well-known/openid-configuration`.
4. HyperShift uploads the discovery doc to `s3://<bucket>/<InfraID>/.well-known/openid-configuration`. These match only if `InfraID == <oidc-id> == path.Base(issuerUrl)`. If seaplane set `InfraID` to the cluster UID, discovery would 404, the OIDC provider could not be validated against the trust policy, and the cluster would never install.

Note the chicken-and-egg this resolves: HyperShift itself cannot solve it, because it only knows the bucket + `InfraID` — never the public issuer URL's path layout. It trusts that the HostedCluster creator has already made `InfraID` line up with the issuer path. (In HyperShift's own self-managed flow, `defaultClusterIDsIfNeeded` generates a random `infraid.New(hcluster.Name)` because HyperShift also constructs the issuer URL as `https://<bucket-site>/<infraID>` — they match by construction.)

**Conclusion**: `InfraID = path.Base(issuerURL)` is a hard functional requirement of HyperShift's shared-bucket OIDC document serving, not an arbitrary seaplane decision. HyperShift's design makes `InfraID` a bucket namespace, not a cluster identity.

### Resulting customer behavior

- **Dedicated VPC (default)**: subnets carry **role tags only** (`kubernetes.io/role/{,internal-}elb`) once the CLI fix (openshift/rosa#3736) lands. Ingress ELBs provision correctly; CCM subnet discovery works because no conflicting `kubernetes.io/cluster/*` tag exists.
- **Shared VPC (follow-up, ROSAENG-1085 AC #4)**: the seaplane-operator will stamp `kubernetes.io/cluster/<infraID>=shared` cross-account onto the cluster's subnets after `infraID` is known (the analog of the v1 clusters-service `step_tag_subnets` step). This scopes subnets to the cluster without pre-coordination at network-creation time.
- **OIDC config reuse**: because `infraID` is pinned to the OIDC config's ID, deleting and recreating an `OidcConfig` releases the issuer-URL suffix for reuse. A **stale `=shared` subnet tag** in a shared VPC can therefore collide with a future cluster that reuses the same OIDC ID. The v1 flow is immune only because its `infraID` is never reused. Mitigation: a finalizer removing `kubernetes.io/cluster/<infraID>=shared` on cluster delete (see [Consequences](#consequences)).
- **Workaround for affected clusters**: retag existing subnets — remove `kubernetes.io/cluster/<name>=owned`, or add `kubernetes.io/cluster/<spec.infraID>=shared`. CCM then finds the subnet and proceeds.
- **Fresh accounts**: the `AWSServiceRoleForElasticLoadBalancing` service-linked role must pre-exist (ephemeral account bootstrap creates it), since CCM's scoped policy cannot create it.

## Current Design — ROSA HCP (v1)

Upstream ROSA (uhc-clusters-service) behaves as follows:

- Customer VPC/subnets carry **role tags only** — infra-ID independent, no pre-coordination with the service.
- The **service** adds the per-cluster subnet tag later, after it generates `infra_id`: `step_tag_subnets.go` calls EC2 `CreateTags` to stamp `kubernetes.io/cluster/<infra_id>=shared` (value **shared**) cross-account onto the subnets.
- The clusters-service preflight reserves tag quota for this (`validateSubnetTagsQuota`, `tagsAddedByHSFlow = 1`).
- ROSA keeps the **owned** cluster tag off subnets entirely; it appears only on the VPC and private hosted zone.
- v1's `infra_id` is generated per cluster (`<cluster_name>-<random>`) and **never reused**, so stale subnet tags cannot collide with future clusters.

## v1 vs v2 Comparison

| Aspect                                | ROSA HCP (v1)                                                                                   | ROSA Seaplane (v2, managed OIDC)                                                                                                    |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `infraID` derivation                  | Generated per cluster: `<name>-<random>` (unique)                                               | Pinned to OIDC config: `path.Base(issuerURL)`                                                                                       |
| `infraID` semantics                   | Cluster infrastructure identity                                                                 | S3 bucket namespace for OIDC documents                                                                                              |
| `infraID` reuse possible              | No (unique per cluster)                                                                         | Yes (OIDC config's issuer suffix is reusable after deletion)                                                                        |
| Subnet tagging at network create      | Role tags only                                                                                  | Role tags only (after rosa CLI fix openshift/rosa#3736; previously also a harmful stack-level `kubernetes.io/cluster/<name>=owned`) |
| Per-cluster subnet tag                | Service stamps `kubernetes.io/cluster/<infra_id>=shared` post-provision (CS `step_tag_subnets`) | Planned: seaplane-operator stamps `kubernetes.io/cluster/<infraID>=shared` post-provision (follow-up, ROSAENG-1085)                 |
| Subnet tag value                      | `shared`                                                                                        | `shared` (planned)                                                                                                                  |
| Subnet tag quota preflight            | Yes (`tagsAddedByHSFlow = 1`)                                                                   | TBD (shared-VPC follow-up)                                                                                                          |
| OIDC document storage                 | Per-cluster issuer URLs / dedicated provider flow                                               | Fleet-wide shared S3 bucket, keyed by `InfraID`                                                                                     |
| Customer OIDC issuer URL              | Service-constructed per cluster                                                                 | Customer-chosen, **immutable** `OidcConfig.spec.issuerUrl`                                                                          |
| Stale-tag collision risk (shared VPC) | None (`infra_id` never reused)                                                                  | Real risk on OIDC-ID reuse; needs a delete-time finalizer to remove `=shared` tags                                                  |
| Ingress ELB creation                  | Works (subnets match CCM filter)                                                                | Works after CLI fix; broke before because stack-propagated `owned` tag ≠ `infraID`                                                  |
| Number of per-cluster IDs             | 2 (name, infra_id)                                                                              | 3 (name, UID, infraID)                                                                                                              |

## Decision

1. **Keep `infraID = path.Base(issuerURL)`** for managed OIDC. Collapsing to a single per-cluster infraID is not required for the bug and is separable hygiene; any change here would break shared-bucket OIDC discovery serving.
2. **Remove the rosa CLI stack-level `kubernetes.io/cluster/<name>=owned` tag injection** (openshift/rosa#3736, base `seaplane-v2`) so seaplane subnets keep only role tags, matching upstream ROSA. The VPC and private hosted zone still get the owned tag from the CloudFormation template.
3. **Add a seaplane-operator subnet-tagging step** (shared-VPC / ROSA parity): stamp `kubernetes.io/cluster/<infraID>=shared` onto the cluster's subnets after `infraID` is known, via cross-account `CreateTags`. Required for shared-VPC subnet scoping (ROSAENG-1085 AC #4); not required for a dedicated single-cluster VPC.
4. **Target the ID-reuse collision concern at the subnet-tag lifecycle, not the `infraID` derivation**: add a finalizer that removes `kubernetes.io/cluster/<infraID>=shared` tags on cluster deletion, mirroring HyperShift's `oidcDocumentsFinalizer` cleanup of S3 objects.

## Consequences

- Positive: dedicated-VPC clusters install correctly with no service-side tagging dependency; the design matches upstream ROSA's proven tagging model.
- Positive: `infraID` choice guarantees OIDC discovery documents are served at the issuer URL, so trust-policy validation and the KAS work without per-cluster issuer URLs or config churn.
- Negative: OIDC config reuse means stale `=shared` subnet tags are a genuine residual risk in shared VPCs until the delete-time finalizer exists.
- Negative: three distinct per-cluster identifiers (name, UID, infraID) remain — a cognitive and debugging cost, accepted for the shared-bucket OIDC requirement.
- Neutral: CCM's scoped policy still requires the pre-existing ELB service-linked role; ephemeral account bootstrap must create it.

## Alternatives Considered

1. **Single per-cluster `infraID` (e.g., cluster UID everywhere)** — rejected: the discovery doc would be uploaded under the wrong S3 key, the issuer URL would 404 on discovery, the OIDC provider could not be validated, and the cluster would never install. Fixable only with per-cluster issuer URLs (losing OIDC config reuse) or teaching the bucket front to rewrite paths.
2. **Have the seaplane-operator tag subnets with `owned` at network-create time** — rejected: it would add a service dependency at network creation and still couldn't know `infraID` before the HostedCluster exists.
3. **Seaplane-operator retags subnets to match the tag CCM expects (add `kubernetes.io/cluster/<infraID>=shared`) as the only fix** — deferred: valid as a workaround, but the primary fix is removing the harmful CLI tag; operator-side tagging is scoped to the shared-VPC follow-up.

## Implementation Reference

| Item                                        | Location / Reference                                                                     |
| ------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `infraID` derivation (managed OIDC)         | `seaplane-operator/internal/render/cluster.go` (ROSAENG-74281)                           |
| Harmful stack-level tag injection (removed) | rosa CLI `cmd/create/network/seaplane.go`, `pkg/network/network.go`                      |
| Primary CLI fix                             | [openshift/rosa#3736](https://github.com/openshift/rosa/pull/3736) (base `seaplane-v2`)  |
| HyperShift OIDC S3 key scheme               | `hostedcluster_controller.go` `reconcileAWSOIDCDocuments` (~line 5391); `gcp_oidc.go:73` |
| v1 subnet tagging (reference model)         | uhc-clusters-service `pkg/clusterprovisioner/acm/rosa/step_tag_subnets.go`               |
| Shared-VPC subnet tagging follow-up         | ROSAENG-1085 (AC #4)                                                                     |
| Bug tracking                                | [ROSAENG-76285](https://redhat.atlassian.net/browse/ROSAENG-76285)                       |
