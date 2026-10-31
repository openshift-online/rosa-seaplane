---
name: onboard-konflux
description: >-
  Onboard an openshift-online HyperFleet repository to Konflux in the existing
  rosa-tenant namespace on kflux-prd-rh02. Use when the user asks to onboard a
  HyperFleet repo or image to Konflux, register a rosa-tenant Application or
  Component, add ImageRepository config in konflux-release-data, or add .tekton
  on-pull-request and on-push pipelines for a new rosa-hyperfleet image.
argument-hint: "[openshift-online/<repo>]"
---

Onboard a HyperFleet GitHub repo to Konflux. Follow [docs/konflux-onboarding.md](../../../docs/konflux-onboarding.md). YAML to copy is in [templates.md](templates.md).

Do not create a tenant, a cluster, or a Quay org. Do not commit, push, or open an MR unless the user asks. Do not fork `konflux-release-data` (CI secrets are not on forks).

## Fixed environment

| Setting        | Value                                                  |
| -------------- | ------------------------------------------------------ |
| Cluster        | `kflux-prd-rh02`                                       |
| Namespace      | `rosa-tenant`                                          |
| GitHub org     | `openshift-online`                                     |
| Quay prefix    | `quay.io/redhat-user-workloads/rosa-tenant/`           |
| Build pipeline | `docker-build-multi-platform-oci-ta`                   |
| Platforms      | `linux/x86_64`                                         |
| EC policy      | `rhtap-releng-tenant/app-interface-standard`           |
| GitHub check   | `Konflux kflux-prd-rh02 / <component>-on-pull-request` |

## Inputs

If `$ARGUMENTS` or the conversation does not already answer these, ask once:

1. **Repo** — `openshift-online/<repo>`.
2. **Images** — for each image: Konflux component name, Quay repo name (the segment after `rosa-tenant/`), Containerfile path, and whether it builds on every PR or only when listed paths change.
3. **Application** — default the repo name. Reuse an application that already exists under `rosa-tenant` when this is another image in an onboarded repo.
4. **Branch** — default `main`.

Names are DNS-1123: lowercase, digits, hyphens, max 63 characters. Component name and Quay repo name may differ (`rosa-hyperfleet-api` builds `platform-api`).

## Checkouts

- Component repo: the working tree if it is that repo, otherwise a sibling checkout.
- `konflux-release-data`: `$KONFLUX_RELEASE_DATA`, else a sibling `konflux-release-data`.
- `openshift/release`: `$OPENSHIFT_RELEASE`, else a sibling `release`.

Update each checkout onto its default branch before editing. `build-single.sh` rewrites the whole `rosa-tenant` auto-generated tree; a stale checkout produces an unrelated diff.

If a checkout is missing, write the files in the reply and name the destination repo. Do not clone unless the user asks.

## Which overlay

Look at `tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/overlay/`.

| Case                                                  | Overlay                                                                                                                    |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| First image of an application that does not exist yet | **Style A** (one overlay). Creates Application, Component, ImageRepository, Enterprise Contract scenario, and ReleasePlan. |
| Another image on an application that already exists   | **Style B** only. Do not add a second Application or ReleasePlan.                                                          |

A new repo with several images uses Style A for the first image and Style B for the rest. The Application name is the repo name. Overlay directories are named after the **component**, with a `main/` subdirectory.

Reference overlays: `rosa-hyperfleet-kube-applier` (Style A, one image) and `zoa-lambda` (Style B, extra image on `rosa-hyperfleet-zoa`).

## 1. konflux-release-data

Create `tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/overlay/<component>/main/` from [templates.md](templates.md).

Append the overlay to `tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/kustomization.yaml`:

```yaml
resources:
  - overlay/<component>/main
```

`rosa-tenant` already has CODEOWNERS. Do not add any.

From `tenants-config/`:

```bash
./build-single.sh rosa
```

That regenerates `auto-generated/cluster/kflux-prd-rh02/tenants/rosa-tenant/`. Do not hand-edit `auto-generated/`. If the command fails kustomize lookup, run `./build-manifests.sh` instead.

Confirm the built Component name, git URL, dockerfile path, and image `rosa-tenant/<quay-repo>` with `visibility: public`.

## 2. Pipelines in the component repo

Copy PipelineRuns. Do not regenerate `pipelineSpec` or edit task-bundle digests. MintMaker bumps those.

Copy from, in order:

1. An existing `.tekton/*-pull-request.yaml` and matching `*-push.yaml` in the same repo.
2. Otherwise `rosa-hyperfleet-kube-applier` `.tekton/rosa-hyperfleet-kube-applier-pull-request.yaml` and `rosa-hyperfleet-kube-applier-push.yaml`.

Write `.tekton/<component>-pull-request.yaml` and `.tekton/<component>-push.yaml`. Change only:

| Field                                           | Pull request                                                               | Push                                                                 |
| ----------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `metadata.name`                                 | `<component>-on-pull-request`                                              | `<component>-on-push`                                                |
| `build.appstudio.openshift.io/repo`             | `https://github.com/openshift-online/<repo>?rev={{revision}}`              | same                                                                 |
| `pipelinesascode.tekton.dev/cancel-in-progress` | `"true"`                                                                   | `"false"`                                                            |
| `pipelinesascode.tekton.dev/on-cel-expression`  | see below                                                                  | see below                                                            |
| labels `application` and `component`            | application, component                                                     | same                                                                 |
| `output-image`                                  | `quay.io/redhat-user-workloads/rosa-tenant/<quay-repo>:on-pr-{{revision}}` | `quay.io/redhat-user-workloads/rosa-tenant/<quay-repo>:{{revision}}` |
| `dockerfile`                                    | Containerfile path                                                         | same                                                                 |
| `path-context`                                  | `.` unless the user said otherwise                                         | same                                                                 |
| `image-expires-after`                           | `5d`                                                                       | omit                                                                 |

Leave `namespace: rosa-tenant` and `build-platforms: [linux/x86_64]`.

**CEL.** Substitute the Branch input for `<branch>` (default `main`). One image, or any image the user said should build on every pull request and every push:

```text
event == "pull_request" && target_branch == "<branch>"
event == "push" && target_branch == "<branch>"
```

Add `pathChanged()` only when the user asked for path-filtered builds. Include the Containerfile, the source directories it copies, `go.mod` and `go.sum` when the module is shared, and `.tekton/<component>-pull-request.yaml` or `-push.yaml`. A Quay `<sha>` tag then exists only for commits that changed those paths. When the user asked for a build on every pull request, do not add `pathChanged()` terms, including on additional images.

**Hermetic.** Leave `hermetic` unset when the Containerfile runs `microdnf`, `dnf`, or `go mod download`. That is the kube-applier default and needs network. Set `hermetic: "true"` and `prefetch-input` only when the build does not fetch modules or RPMs, or the user asks. One prefetch entry per module: `{"type":"gomod","path":"<dir>"}` (`path` omitted for the repo root). Copy those two params from `rosa-hyperfleet-api` `.tekton/rosa-hyperfleet-api-pull-request.yaml` if the file you copied does not have them. Do not rewrite the Containerfile in this task.

## 3. MintMaker

If `renovate.json` is missing, copy [renovate.json](renovate.json) and set `dockerfile.managerFilePatterns` to every Containerfile or Dockerfile the pipelines build (plus `ci/Containerfile` when present). Do not add `lgtm` or `approved` labels. Those labels are merge approval, and Tide will treat them as a review.

If it exists, keep it. Ensure `dockerfile`, `tekton`, and `gomod` (when the repo has `go.mod`) are in `enabledManagers`, and that `managerFilePatterns` include the new Containerfile and `/^\\.tekton\\/.*\\.ya?ml$/`.

When the Makefile has a `mod-tidy` target, add the `gomod` `postUpgradeTasks` rule from `rosa-hyperfleet-api` `renovate.json` (`make mod-tidy`, `executionMode: branch`, file filters `**/go.mod` and `**/go.sum`). Do not copy repo-specific `enabled: false` package rules.

## 4. Component repo doc

Add or update `docs/konflux.md` using the template in [templates.md](templates.md). Link the HyperFleet guide rather than duplicating it.

## 5. Branch protection

Do this only after a pull request has reported the Konflux check. Requiring the context earlier blocks every PR.

Edit `core-services/prow/02_config/openshift-online/<repo>/_prowconfig.yaml` in `openshift/release`.

- Require `Konflux kflux-prd-rh02 / <component>-on-pull-request` only when that pipeline's CEL has **no** `pathChanged()` filter.
- Leave path-filtered checks off the required list. Unrelated PRs never report them, so GitHub will wait forever.
- If the file does not exist, create it from the template in [templates.md](templates.md). Copy `ci/prow/...` contexts from the existing file when there is one. Do not invent Prow job names.
- Add the `red-hat-konflux-kflux-prd-rh02[bot]` Tide query from the template when that repo is not already in one. Search `02_config` first so you do not duplicate Tide queries.

Prow keeps lint, unit, integration, and e2e. Do not delete ci-operator image jobs.

## 6. GitOps pin

After the first green `<component>-on-push` on the selected branch, pin the **plain full git SHA** in the consumer (usually `argocd/config/.../values.yaml` in this repo):

```yaml
image:
  repository: quay.io/redhat-user-workloads/rosa-tenant/<quay-repo>
  tag: "<full-commit-sha>"
```

Do not pin `:latest`, `:on-pr-<sha>`, or a `.git` / `.prefetch` suffix. Skip this step when no consumer exists yet, and say so.

## Merge order

Tell the user to merge in this order. Open the MRs only if they ask.

1. `konflux-release-data` — Component must exist before a pipeline can push.
2. Component repo — `.tekton/`, `renovate.json`, `docs/konflux.md`.
3. Confirm a green `*-on-pull-request` check on a PR. If no check appears, the GitHub App `red-hat-konflux-kflux-prd-rh02` does not see the repo. Style A inherits `build.appstudio.openshift.io/request: configure-pac` from the tenant base; do not remove it. For Style B, add that annotation only when the app is not already installed.
4. `openshift/release` branch protection.
5. After a green `*-on-push` on the selected branch, pin the SHA.

## Report

When the edits are done, list:

- Application, component, Quay image, PipelineRun names, and whether the on-PR check is required or path-filtered
- Files changed in each checkout
- `build-single.sh rosa` result
- Which of the five merge steps are still manual
