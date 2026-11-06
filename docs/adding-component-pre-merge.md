# Cross-Component E2E Testing

Component repositories (e.g., `rosa-seaplane-api`) can run the rosa-seaplane e2e test suite against a full ephemeral environment with their PR-built image deployed.

## Overview

A reusable [step-registry workflow](https://github.com/openshift/release/tree/master/ci-operator/step-registry/rosa-seaplane/ephemeral-e2e) in `openshift/release` handles everything:

1. **Image build** — ci-operator builds the component's Docker image from the PR source
2. **Resolve OCP image** — Optionally resolves `OCP_RELEASE_STREAM` to the latest accepted OCP payload for the e2e HCP cluster (skipped when unset; see [OCP release image selection](#ocp-release-image-selection))
3. **Image push** — The image is copied to `quay.io/rrp-dev-ci/` using `oc image mirror` from the OCP `cli` image (public, so EKS can pull it without credentials), tagged `ci-<PR>-<BUILD_ID>`
4. **Provision** — Ephemeral environment provisioned from `rosa-seaplane` main, with the component's Helm values deep-merged with an inline YAML override
5. **E2E tests** — The RRP testing suite (`./ci/e2e-tests.sh`) from rosa-seaplane runs against the environment
6. **Teardown** — Ephemeral environment torn down (fire-and-forget)

## Workflow Steps

| Step                              | Image              | Purpose                                                                     |
| --------------------------------- | ------------------ | --------------------------------------------------------------------------- |
| `rosa-seaplane-resolve-ocp-image` | `rosa-seaplane-ci` | Resolves `OCP_RELEASE_STREAM` to an OCP release pullspec (no-op when unset) |
| `rosa-seaplane-image-push`        | `ocp/4.21:cli`     | Copies CI-built image to quay.io using `oc image mirror`                    |
| `rosa-seaplane-provision`         | `rosa-seaplane-ci` | Calls ephemeral provider with YAML overrides, provisions environment        |
| `rosa-seaplane-e2e`               | `rosa-seaplane-ci` | Clones this repo, runs `./ci/e2e-tests.sh`                                  |
| `rosa-seaplane-teardown`          | `rosa-seaplane-ci` | Clones this repo, runs teardown                                             |

The `rosa-seaplane-ci` image is built from `ci/Containerfile` and promoted to the CI registry on every merge to `main` of `openshift-online/rosa-seaplane`.

## CI Credentials

| Secret                                    | Purpose                                             |
| ----------------------------------------- | --------------------------------------------------- |
| `rosa-regional-platform-dev-ci-quay-push` | Robot account for pushing to `quay.io/rrp-dev-ci/`  |
| `rosa-regional-platform-ephemeral-creds`  | AWS credentials for provisioning, e2e, and teardown |

Managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-regional-platform-int/).

## Override Mechanism

The provision step deep-merges a YAML fragment into a target file in the rosa-seaplane repo before the ephemeral provider commits and pushes the CI branch. This is used to inject PR-built component images into Helm values files.

The override is configured via env vars in the CI config:

| Variable                           | Description                                                                                                                                                                             |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ROSA_REGIONAL_COMPONENT_NAME`     | Component name for logging (e.g., `platform-api`).                                                                                                                                      |
| `ROSA_REGIONAL_HELM_VALUES_FILE`   | Path to the target file in this repo (e.g., `argocd/config/regional-cluster/platform-api/values.yaml`).                                                                                 |
| `ROSA_REGIONAL_HELM_OVERRIDE_YAML` | Inline YAML fragment to deep-merge into the target file. Use `IMAGE_REPO` and `IMAGE_TAG` as placeholders — they are replaced with the actual image reference from the image-push step. |
| `ROSA_REGIONAL_QUAY_DEST_REPO`     | Public quay.io repository for the CI-built image.                                                                                                                                       |

The deep merge works as follows:

- **Dicts** are merged recursively (override wins on conflicts).
- **Lists of dicts** are matched by `name` key — a matching item is merged, unmatched items are appended.
- **All other values** (scalars, lists of non-dicts) are replaced by the override.

### Image override example

For a values file with this structure:

```yaml
platformApi:
  app:
    image:
      repository: quay.io/rrp/platform-api
      tag: latest
```

The inline override YAML would be:

```yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  platformApi:
    app:
      image:
        repository: IMAGE_REPO
        tag: IMAGE_TAG
```

`IMAGE_REPO` and `IMAGE_TAG` are replaced at runtime with the actual image pushed by the image-push step.

### Chart version override example

For overriding a Helm chart dependency version in `Chart.yaml`:

```yaml
ROSA_REGIONAL_HELM_VALUES_FILE: argocd/config/shared/karpenter/Chart.yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  dependencies:
    - name: karpenter
      version: 1.15.1
```

The `name: karpenter` entry is matched against the existing dependencies list, and only the `version` field is updated. No placeholders needed since this isn't an image override.

## OCP release image selection

By default the e2e HCP cluster uses the ephemeral environment's built-in OCP release image, so most component repos can ignore this. To run against a specific OCP stream instead, set `OCP_RELEASE_STREAM`; the [`rosa-seaplane-resolve-ocp-image`](https://github.com/openshift/release/tree/master/ci-operator/step-registry/rosa-seaplane/resolve-ocp-image) step resolves it to a public multi-arch pullspec the ephemeral environment can pull (it is a no-op when unset):

- `ocp-branch-candidate` — newest accepted GA/z-stream/RC for the branch's OCP version. Suited to presubmits, so a failure points at the change under test.
- `ocp-branch-nightly` — newest accepted multi-arch nightly for the branch's OCP version. Suited to periodics, to catch OCP regressions early.

Both track the branch's own `release-X.Y` version (and fall back to the newest older version with accepted payloads), so `config-brancher` copies stay correct. See the step's `documentation` for the full resolution logic and other accepted values.

## SOP: Onboarding a New Component Repository

### Prerequisites

- The component has a `Dockerfile` that ci-operator can build
- The component is deployable via a Helm chart in this repo (rosa-seaplane)

### Step 1: Create quay.io repository

Create a **public** repository under `quay.io/rrp-dev-ci/` for the component. Grant the existing robot account (used by `rosa-regional-platform-dev-ci-quay-push`) push access.

### Step 2: Add CI config in openshift/release to your repository's job config

Edit `ci-operator/config/<repo>/<org>-<repo>-<branch>.yaml`, e.g. [here](https://github.com/openshift/release/pull/76818/changes#diff-e1f3e71b4382080dfc304ae3b05b7cc97e95f2bf6cf49d744c4901fdc55274e1) for [rosa-seaplane-api](https://github.com/openshift-online/rosa-seaplane-api):

```yaml
images:
  - dockerfile_path: Dockerfile
    to: <pipeline-image-name>

tests:
  # ... existing tests ...
  - always_run: false
    as: rosa-seaplane-compatibility-e2e
    steps:
      dependencies:
        CI_COMPONENT_IMAGE: <pipeline-image-name>
      env:
        ROSA_REGIONAL_COMPONENT_NAME: "<component-name>"
        ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
          <yaml-fragment-with-IMAGE_REPO-and-IMAGE_TAG-placeholders>
        ROSA_REGIONAL_HELM_VALUES_FILE: "argocd/config/regional-cluster/<component-name>/values.yaml"
        ROSA_REGIONAL_QUAY_DEST_REPO: "quay.io/rrp-dev-ci/<component>"
      workflow: rosa-seaplane-ephemeral-e2e
```

Where:

- `<pipeline-image-name>` — the `to` field from your `images` section (used as the dependency name)
- `<component-name>` — the component's directory name under `argocd/config/<regional|management>-cluster/` in this repo (e.g., `platform-api`)
- `ROSA_REGIONAL_QUAY_DEST_REPO` — the public quay.io repo from step 1

### Step 3: Regenerate and submit

```bash
cd openshift/release
make update
make checkconfig
# Open PR
```

### Step 4: Trigger

On any PR in the component repo:

```
/test rosa-seaplane-compatibility-e2e
```

## Examples

Consumers of the `rosa-seaplane-ephemeral-e2e` workflow, from simplest to most involved:

- **Single-image Helm component** — one image deep-merged into an ArgoCD values file. The canonical example is [`rosa-seaplane-api`](https://github.com/openshift-online/rosa-seaplane-api), covered step by step in [the onboarding SOP above](#sop-onboarding-a-new-component-repository).
- **Multi-image / Terraform component (ZOA)** — multiple images injected into a Terraform defaults file.
- **HyperShift (pre-merge + nightly)** — two images, plus an OCP payload matrix across presubmit and periodic flows.

### Multi-Image / Terraform-Deployed Components (ZOA)

Components that deploy through **Terraform** (not ArgoCD Helm) and/or have **multiple images** require a modified approach. ZOA is the canonical example:

#### Key Differences

| Aspect          | Standard (API)                         | Terraform (ZOA)                                  |
| --------------- | -------------------------------------- | ------------------------------------------------ |
| Image count     | 1 (or 2 for API)                       | 3 (Lambda + Runner + Boundary)                   |
| Override target | `argocd/config/.../values.yaml` (Helm) | `config/defaults.yaml` (Terraform via render.py) |
| Image push step | `rosa-seaplane-image-push` (shared)    | Same step — uses `ROSA_REGIONAL_COMPONENTS`      |
| Placeholders    | `IMAGE_REPO`, `IMAGE_TAG`              | `IMAGE_REPO`, `IMAGE_TAG` (per-image, same tag)  |

#### `ROSA_REGIONAL_COMPONENTS` for ZOA

ZOA uses the same `ROSA_REGIONAL_COMPONENTS` mechanism as the API repo but targets
`config/defaults.yaml` (Terraform) instead of ArgoCD Helm values files. Map pipeline images
with `steps.dependencies` (`CI_IMAGE_1` … `CI_IMAGE_8`); each list entry's `image:` names one
of those env vars:

```yaml
steps:
  dependencies:
    CI_IMAGE_1: zoa-lambda
    CI_IMAGE_2: zoa-runner
    CI_IMAGE_3: zoa-boundary
  env:
    ROSA_REGIONAL_COMPONENTS: |
      - image: CI_IMAGE_1
        repo: quay.io/rrp-dev-ci/zoa-lambda
        target: config/defaults.yaml
        override:
          regional_cluster:
            zoa_lambda_image_tag: IMAGE_TAG
            zoa_lambda_source_image: IMAGE_REPO
      - image: CI_IMAGE_2
        repo: quay.io/rrp-dev-ci/zoa-runner
        target: config/defaults.yaml
        override:
          regional_cluster:
            zoa_runner_image_tag: IMAGE_TAG
            zoa_runner_source_image: IMAGE_REPO
      - image: CI_IMAGE_3
        repo: quay.io/rrp-dev-ci/zoa-boundary
        target: config/defaults.yaml
        override:
          regional_cluster:
            zoa_boundary_image_tag: IMAGE_TAG
            zoa_boundary_source_image: IMAGE_REPO
```

All entries target the same file (`config/defaults.yaml`) — the provision step applies them
sequentially via deep-merge. The ephemeral provider then runs `render.py`, which regenerates
`deploy/.../terraform.json` with the CI-built image tags. Terraform picks them up during
provisioning (Lambda mirrored to RC ECR via skopeo; Runner Jobs and Boundary ECS pull the source registry directly — typically Quay).

#### Reference

- **CI config**: [`openshift/release` — `ci-operator/config/openshift-online/rosa-seaplane-zoa/`](https://github.com/openshift/release/blob/master/ci-operator/config/openshift-online/rosa-seaplane-zoa/openshift-online-rosa-seaplane-zoa-main.yaml)

### HyperShift Pre-Merge & Nightly E2E

The [`openshift/hypershift`](https://github.com/openshift/hypershift) repo runs the same
`rosa-seaplane-ephemeral-e2e` workflow to validate HyperShift changes against a full
ephemeral environment. Two images from HyperShift are involved, deployed independently:

| Image                 | Deployed as                                        | Override target                                           |
| --------------------- | -------------------------------------------------- | --------------------------------------------------------- |
| `hypershift-operator` | HyperShift operator (HO) on the Management Cluster | `argocd/config/management-cluster/hypershift/values.yaml` |
| `hypershift`          | Control-plane-operator (CPO) on hosted clusters    | `argocd/config/regional-cluster/seaplane/values.yaml`     |

#### Test matrix

The two flows differ in which images they override and which OCP payload they run against (see [OCP release image selection](#ocp-release-image-selection) for the stream values):

| Flow                      | Trigger                                        | HO (operator)                          | CPO (`hypershift`)                | OCP payload            |
| ------------------------- | ---------------------------------------------- | -------------------------------------- | --------------------------------- | ---------------------- |
| **Pre-merge** (presubmit) | `/test e2e-rosa-seaplane` on a PR (`optional`) | PR build                               | PR build                          | `ocp-branch-candidate` |
| **Nightly** (periodic)    | daily at 08:00 UTC, per `release-X.Y` branch   | published `hypershift-operator:latest` | from OCP payload (not overridden) | `ocp-branch-nightly`   |

- **Pre-merge** overrides **both** HO and CPO from the one PR build (via
  `ROSA_REGIONAL_EXTRA_COMPONENTS`), so a developer validates their exact change end-to-end
  before merge.
- **Nightly** overrides **only HO** (`ROSA_REGIONAL_HELM_OVERRIDE_YAML` → the published
  operator image) and lets CPO come from the OCP payload, catching regressions against fresh
  nightly payloads without a PR. Defined in the `__periodics.yaml` variant per release branch.

#### Reference

- **CI config**: [`openshift/release` — `ci-operator/config/openshift/hypershift/`](https://github.com/openshift/release/tree/master/ci-operator/config/openshift/hypershift)
  (`openshift-hypershift-main.yaml` + `openshift-hypershift-release-*__periodics.yaml`)
