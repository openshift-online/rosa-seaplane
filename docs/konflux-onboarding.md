# Konflux onboarding guide

Team reference for onboarding Seaplane container images to Konflux and keeping new builds on the Konflux path.

> **Audience:** This file is in a **public** GitHub repo. It contains no secrets or customer data. Some linked resources require Red Hat access: `gitlab.cee.redhat.com`, the Konflux UI, and the internal Google design doc below.

## Konflux environment (Seaplane)

| Setting                     | Value                                                        |
| --------------------------- | ------------------------------------------------------------ |
| Konflux cluster             | `kflux-prd-rh02`                                             |
| Tenant namespace            | `rosa-tenant`                                                |
| Quay path prefix            | `quay.io/redhat-user-workloads/rosa-tenant/`                 |
| Required PR check (example) | `Konflux kflux-prd-rh02 / rosa-seaplane-api-on-pull-request` |

**Links**

- [Konflux UI — `rosa-seaplane` application](https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/rosa-tenant/applications/rosa-seaplane/activity)
- [Konflux UI — all `rosa-tenant` applications](https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/rosa-tenant/applications)
- [Seaplane Konflux design doc](https://docs.google.com/document/d/1KVGj_3lyGghVzm94G5iskIIkHkZyabvHTRue1DCwF-c/edit?tab=t.0#heading=h.o40dh15jzkv7)
- [`konflux-release-data` overlays for `rosa-tenant`](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/main/tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/overlay?ref_type=heads)

## Goals

- **Konflux builds** every merge to `main` and every applicable pull request, according to each component's configured path triggers (supply chain + attestation).
- **Prow** keeps lint, unit, integration, and e2e orchestration (Hypershift-style hybrid — do not remove Prow image jobs until deliberately cut over).
- **GitOps** (this repo's Helm values) pins `quay.io/redhat-user-workloads/rosa-tenant/<image>:<sha>`.

Repo-specific Quay tag conventions for `platform-api` and `seaplane-operator`: [rosa-seaplane-api `docs/konflux/quay-image-tags.md`](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/konflux/quay-image-tags.md).

To apply this checklist to a new `openshift-online` HyperFleet repository, use the `onboard-konflux` skill (`.claude/skills/onboard-konflux/SKILL.md`). It registers the component in `rosa-tenant`, copies the `.tekton` pipelines, and adds MintMaker config. It does not open the GitLab or GitHub merge requests unless asked.

## Onboarding checklist (per component)

Copy this checklist for each new image. **Onboarded** means steps 1–5 are complete: green PR build before merge, green `main` push build after merge, and GitOps pointed at the Konflux image.

| #   | Step                                               | Where                                                                                                                                                                                                                                    | Done when                                                                                   |
| --- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 1   | Register Application + Component + ImageRepository | [`konflux-release-data` for `rosa-tenant`](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/main/tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/overlay?ref_type=heads) overlay under `…/overlay/<app>/main/` | MR merged; Component visible in Konflux UI                                                  |
| 2   | Add build pipelines                                | App repo `.tekton/*-on-pull-request.yaml` + `*-on-push.yaml`                                                                                                                                                                             | PR merged (Konflux bootstrap PR or hand-copied from a reference repo)                       |
| 3   | Wire CI gates                                      | [`openshift/release`](https://github.com/openshift/release) branch protection + ci-operator if needed                                                                                                                                    | Required Konflux on-PR context(s) added for the component; see branch-protection note below |
| 4   | Validate builds                                    | Konflux UI / GitHub checks                                                                                                                                                                                                               | Green `*-on-pull-request` on a test PR and green `*-on-push` on `main`                      |
| 5   | Point consumers at Konflux image                   | `rosa-seaplane` ArgoCD values (or other deploy repo)                                                                                                                                                                                     | `repository` + `tag: "<full-sha>"` under `redhat-user-workloads/rosa-tenant/…`              |

**Rule for new work:** any new container image that ships to staging or production must complete steps 1–3 before merge and steps 4–5 before release. Do not use ad-hoc personal Quay repos for runtime images.

**Branch protection (step 3):** Tekton on-PR pipelines often use CEL `pathChanged()` filters — a check only runs when relevant paths change. Require the Konflux context for a component only when that pipeline applies to the PR; do not mark path-filtered checks as unconditionally required on GitHub or unrelated PRs stay blocked. During rollout, Prow/Tide `skip-unknown-contexts: true` can ignore optional contexts not yet reported — that is a Tide setting, not a GitHub branch-protection substitute.

### Reference implementation

Use [`rosa-seaplane-api`](https://github.com/openshift-online/rosa-seaplane-api) as the template for step 2:

- `platform-api` — `.tekton/rosa-seaplane-api-*.yaml`
- `seaplane-operator` — `.tekton/rosa-seaplane-operator-*.yaml`

For step 1, copy an existing overlay (for example `rosa-boundary`, `rosa-seaplane-zoa`, or `rosa-seaplane-api` under `rosa-tenant`) and adjust:

- `application-patch.yaml` — Application name
- `component-patch.yaml` — Component name, git URL, branch, `spec.build-nudges-ref` if needed
- `image-repository.yaml` — Quay path under `redhat-user-workloads/rosa-tenant/`

Run `build-manifests.sh` in `konflux-release-data/tenants-config` before opening the MR.

### New repository vs new component

| Case                                                                 | Application                 | Component          | Repo change                      |
| -------------------------------------------------------------------- | --------------------------- | ------------------ | -------------------------------- |
| New image in an existing repo (like operator in `rosa-seaplane-api`) | Reuse `rosa-seaplane`       | New component name | Add `.tekton/<component>-*.yaml` |
| New standalone repo (like `rosa-seaplane-zoa`)                       | New or existing application | New component      | Full `.tekton/` + release config |

## Prow and Konflux responsibilities

| Concern                                 | Owner                                                |
| --------------------------------------- | ---------------------------------------------------- |
| Image build + attestation               | Konflux                                              |
| `gomod` / Dockerfile / Tekton dep bumps | MintMaker (`renovate.json` in each onboarded repo)   |
| Lint, verify, unit, integration, e2e    | Prow                                                 |
| Required checks before merge            | Konflux on-PR (when path triggers apply) + Prow jobs |

Konflux can only attest images **it** built. Released images must come from Konflux push pipelines, not from ci-operator `images:` alone.

## Dependency PRs (MintMaker)

Each onboarded app repo uses a root `renovate.json` for MintMaker (see [`rosa-seaplane-api`](https://github.com/openshift-online/rosa-seaplane-api/blob/main/renovate.json) for an example):

- **gomod**, **dockerfile**, **tekton** managers enabled
- Patch/minor/digest updates: automerge when Prow + Konflux pass
- Major updates: manual review (`major-update`, `manual-review-required`)

MintMaker runs on a **~4-hour base schedule**. The `tekton` manager runs on Saturdays after 05:00 UTC. To rerun CI on an open dep PR without waiting:

- Comment **`/retest`** on the PR (Konflux + Prow)
- Add the **`rebase`** label (or use the rebase checkbox in the Renovate PR body) to refresh the branch against `main`

Automerge runs on a **subsequent** MintMaker pass after all checks are green and the branch is up to date with `main`.

## Ephemeral / PR testing

PR builds produce:

```text
quay.io/redhat-user-workloads/rosa-tenant/<image>:on-pr-<full-commit-sha>
```

Tags expire after **5 days**. To test a `platform-api` change in an ephemeral RC:

1. Open PR → wait for green `*-on-pull-request`
2. Pin ephemeral config to `:on-pr-<sha>` (see [development environment](development-environment.md))
3. Run ephemeral resync

Post-merge pins use the plain `<sha>` tag — see [quay-image-tags.md](https://github.com/openshift-online/rosa-seaplane-api/blob/main/docs/konflux/quay-image-tags.md) in `rosa-seaplane-api`.

## Troubleshooting

| Symptom                               | Likely cause                                 | Action                                                                                          |
| ------------------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| No Konflux check on PR                | PAC not configured or GitHub App not on repo | Set `build.appstudio.openshift.io/request: configure-pac` on the Component; confirm app install |
| `on-pr-*` build fails, `main` is fine | Stale Tekton task refs                       | Merge Konflux/MintMaker Tekton bump PRs; `/retest` open dep PRs                                 |
| EC (Enterprise Contract) failures     | Dockerfile or base image policy              | Check Konflux UI pipeline log; align with EC policy                                             |
| Image not pullable from RC/EKS        | ImageRepository visibility / pull secret     | Konflux admin or registry credentials                                                           |
| MintMaker PR stuck                    | Real dep breakage vs infra                   | Read `renovate/artifacts` and Prow logs; close bad PRs                                          |

## External references

- [Konflux: onboarding from GitHub](https://konflux-ci.dev/docs/building/creating-github/)
- [Konflux: running / retriggering pipelines](https://konflux-ci.dev/docs/building/running/) (`/retest`, `/ok-to-test`)
- [MintMaker user guide](https://konflux-ci.dev/docs/mintmaker/user/)
- [Create tenant namespace](https://konflux.pages.redhat.com/docs/users/getting-started/create-tenant-namespace.html) (Seaplane reuses `rosa-tenant` — new tenants rarely needed)
- [Seaplane Konflux design doc](https://docs.google.com/document/d/1KVGj_3lyGghVzm94G5iskIIkHkZyabvHTRue1DCwF-c/edit?tab=t.0#heading=h.o40dh15jzkv7)
