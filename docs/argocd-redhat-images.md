# Argo CD Red Hat image pin (ROSAENG-67992)

OpenShift GitOps does not publish a Helm chart that can run on EKS (operator + CR, OLM). The wrapper stays [argo-helm](https://argoproj.github.io/argo-helm) `argo-cd`, held at **10.9.6** (`appVersion` **v3.5.3**) so it matches GitOps **1.22** (Argo CD **3.5.3**, Dex **2.45.1**). The GitOps operator and `redhat-cop/gitops-operator` are not installed on EKS.

Chart **10.11.6** is Argo CD **v3.5.6**. That is not a tag swap onto GitOps 1.22. Do not bump the wrapper past 10.9.6 until a GitOps `argocd-rhel9` tag is that chart’s `appVersion`.

## Pin

| Image   | Repository                                           | GitOps 1.22.3 (RHSA-2026:94584, amd64)                                            |
| ------- | ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| Argo CD | `registry.redhat.io/openshift-gitops-1/argocd-rhel9` | `v1.22.3@sha256:a4492e603ffa70327ac27094723819e55f2b2b038338eea8eac2e7c2f425a420` |
| Dex     | `registry.redhat.io/openshift-gitops-1/dex-rhel9`    | `v1.22.3@sha256:a6d9927bb83c40da1e1ddec30ac41e15c9c4ea98228d05e57468a4d5bd590d1b` |
| Redis   | community `redis-ha` (`dandydeveloper`)              | GitOps `redis-rhel9` is not a drop-in for this HA subchart                        |

`argo-helm` 10.9.6 sets `args: [/usr/local/bin/argocd-server, …]` (no `command`). The GitOps image must provide that path; this is not the cert-manager “flags as argv0” case.

## Comparison

| Source                                                                                                                                  | Version              | Argo CD    |
| --------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ---------- |
| Wrapper `argocd/config/shared/argocd/Chart.yaml` (this pin)                                                                             | argo-cd **10.9.6**   | **v3.5.3** |
| argo-helm 10.11.6 (do not use with GitOps 1.22)                                                                                         | 10.11.6              | v3.5.6     |
| [OpenShift GitOps 1.22](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/release_notes/gitops-release-notes) | GitOps 1.22.0 matrix | **3.5.3**  |
| OpenShift GitOps 1.21                                                                                                                   | 1.21.0               | 3.4.3      |

## Pull secret

`registry.redhat.io` needs `pull-secret` in `argocd`. ECS bootstrap seeds it from SSM `/infra/pull-secret` before the first Helm install. The wrapper ExternalSecret refreshes it after ESO is up (`creationPolicy: Orphan`).
