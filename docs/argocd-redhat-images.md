# Argo CD Red Hat image pins (ROSAENG-67992)

OpenShift GitOps does not publish a Helm chart that can run on EKS (operator + CR, OLM). The wrapper stays [argo-helm](https://argoproj.github.io/argo-helm) `argo-cd`, held at **10.9.6** (`appVersion` **v3.5.3**) so it matches GitOps **1.22** (Argo CD **3.5.3**, Dex **2.45.1**). The GitOps operator and `redhat-cop/gitops-operator` are not installed on EKS.

Chart **10.11.6** is Argo CD **v3.5.6**. That is not a tag swap onto GitOps 1.22. Do not bump the wrapper past 10.9.6 until a GitOps `argocd-rhel9` tag is that chart’s `appVersion`.

## Pin

| Image   | Repository                                               | Tag / digest                                                                      |
| ------- | -------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Argo CD | `registry.redhat.io/openshift-gitops-1/argocd-rhel9`     | `v1.22.3@sha256:a4492e603ffa70327ac27094723819e55f2b2b038338eea8eac2e7c2f425a420` |
| Dex     | `registry.redhat.io/openshift-gitops-1/dex-rhel9`        | `v1.22.3@sha256:a6d9927bb83c40da1e1ddec30ac41e15c9c4ea98228d05e57468a4d5bd590d1b` |
| Valkey  | `registry.access.redhat.com/hi/valkey`                   | `9.2.0` (pin the registry digest before promotion)                                |
| HAProxy | `registry.redhat.io/openshift4/ose-haproxy-router-rhel9` | `v4.20.0` (pin the registry digest before promotion)                              |

The Argo CD wrapper bundles `redis-ha` **4.38.0**. Its Valkey and HAProxy image
overrides are in `argocd/config/shared/argocd/values.yaml`. The Redis and
Sentinel containers invoke `valkey-server` and `valkey-sentinel`; the subchart's
generated init and health scripts still call `redis-cli`, so the Valkey image
must include Valkey's Redis-compatible `redis-cli` symlink. The router image is
run as HAProxy directly, rather than through its OpenShift router entrypoint.
The same HAProxy command patch is applied by Helm's post-renderer during ECS
bootstrap and by the Kustomize operand during steady-state Argo CD syncs.

This Argo CD deployment is part of ROSA Seaplane but is bootstrapped on EKS,
not inside an OpenShift/ROSA cluster. It cannot rely on the `restricted-v2` SCC
to assign volume groups, so Redis and HAProxy use `fsGroup: 1001` for their
writable `emptyDir` mounts and leave `runAsUser` unset to use the images'
non-root defaults. If these pods are ever moved onto OpenShift, use a separate
values overlay that delegates `runAsUser` and `fsGroup` to the SCC.

`argo-helm` 10.9.6 sets `args: [/usr/local/bin/argocd-server, …]` (no `command`). The GitOps image must provide that path; this is not the cert-manager “flags as argv0” case.

Repo-server `copyutil` is different. The chart default is `cp --update=none`, which RHEL 9 coreutils does not have (`Init:CrashLoopBackOff`). Dex’s copyutil is hardcoded `cp -f` of the same `/usr/local/bin/argocd` binary. Override `argo-cd.repoServer.copyutil.extraArgs` to `-n`.

## Comparison

| Source                                                                                                                                  | Version              | Argo CD    |
| --------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ---------- |
| Wrapper `argocd/config/shared/argocd/Chart.yaml` (this pin)                                                                             | argo-cd **10.9.6**   | **v3.5.3** |
| argo-helm 10.11.6 (do not use with GitOps 1.22)                                                                                         | 10.11.6              | v3.5.6     |
| [OpenShift GitOps 1.22](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/release_notes/gitops-release-notes) | GitOps 1.22.0 matrix | **3.5.3**  |
| OpenShift GitOps 1.21                                                                                                                   | 1.21.0               | 3.4.3      |

## Pull secret

`registry.redhat.io` needs `pull-secret` in `argocd`. ECS bootstrap seeds it from SSM `/infra/pull-secret` before Helm and sets `pullSecret.externalSecret.enabled=false` so Helm does not apply the ExternalSecret (ESO CRD is not installed yet; `SkipDryRunOnMissingResource` is Argo CD-only). After ESO syncs, Argo CD creates the ExternalSecret (`creationPolicy: Orphan`) to refresh the Secret.

Bootstrap always runs `helm upgrade --install --wait --timeout=20m`. It does not skip when `argocd-server` already exists: a timed-out first install still leaves that Deployment, and skipping leaves a failed Helm release. On Helm failure the task dumps pods, jobs, events, and `helm status` in `argocd`.
