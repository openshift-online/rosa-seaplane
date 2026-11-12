# Argo CD Red Hat image pin (ROSAENG-67992)

OpenShift GitOps `argocd-rhel9` is **not** pinned onto the community Helm chart. The GitOps operand and `argo-helm` 10.11.6 are not the same Argo CD version. Swapping the tag would run a 3.4 binary against a 3.5 chart.

The chart stays [argo-helm](https://argoproj.github.io/argo-helm) `argo-cd` **10.11.6**. The OpenShift GitOps operator and `redhat-cop/gitops-operator` are not installed on EKS.

## Comparison

| Source                                                                                                                                  | Version                        | Argo CD    |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ | ---------- |
| Wrapper `argocd/config/shared/argocd/Chart.yaml`                                                                                        | argo-cd **10.11.6** (current)  | **v3.5.6** |
| Card baseline `argo-cd` 9.3.4                                                                                                           | 9.3.4                          | **v3.2.5** |
| [OpenShift GitOps 1.21](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.21/html/release_notes/gitops-release-notes) | GitOps 1.21.0 (latest GA line) | **3.4.3**  |
| OpenShift GitOps 1.20                                                                                                                   | 1.20.0                         | 3.3.2      |
| OpenShift GitOps 1.18 (card example `v1.18.6`)                                                                                          | 1.18.0                         | 3.1.6      |
| OpenShift GitOps 1.16                                                                                                                   | 1.16.0                         | 2.14.4     |

The card’s “GitOps 1.x is Argo CD 2.x” is stale: 1.17+ tracks Argo CD 3.x. The remaining gap is **3.4.3 (newest RH operand) vs 3.5.6 (current chart)**.

Catalog:

- [`openshift-gitops-1/argocd-rhel9`](https://catalog.redhat.com/en/software/containers/openshift-gitops-1/argocd-rhel9/6764feceaa6967a7892823bd) — GitOps stream tags (`v1.18.x`, `v1.20.x`, `v1.21.x`), not Argo CD `v3.5.6`
- [`openshift-gitops-1/dex-rhel9`](https://catalog.redhat.com/en/software/containers/openshift-gitops-1/dex-rhel9/69784d36327b0a10e47249e0) — exists; GitOps 1.21 ships Dex **2.45.0**, chart 10.11.6 bumped Dex to **2.46.1**
- `openshift-gitops-1/redis-rhel9` — not found as a drop-in for this wrapper. HA Redis here is the `redis-ha` subchart (`dandydeveloper`), not the GitOps operator Redis pod

## Decision

Do not override `argo-cd.global.image` (or Dex/Redis) until a GitOps `argocd-rhel9` tag matches this chart’s `appVersion`. Re-check when GitOps ships Argo CD 3.5.x, or if the wrapper chart is deliberately held at a GitOps-aligned `appVersion`.
