# Konflux onboarding templates

Replace `APPLICATION`, `COMPONENT`, `QUAY_REPO`, `GIT_HTTPS_URL`, `DOCKERFILE`, `BRANCH`, and `REPO`. `REPO` is the repository name without the `openshift-online/` org. Quote style matches the merged `rosa-tenant` overlays.

Overlay path:

```text
tenants-config/cluster/kflux-prd-rh02/tenants/rosa-tenant/overlay/COMPONENT/main/
```

## Style A — first image of a new application

`kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../base
  - image-repository.yaml
patches:
  - path: component-patch.yaml
    target:
      kind: Component
  - path: integrationtestscenario-patch.yaml
    target:
      kind: IntegrationTestScenario
      name: example-main-enterprise-contract
  - path: releaseplan-patch.yaml
    target:
      kind: ReleasePlan
  - path: application-patch.yaml
    target:
      kind: Application
```

`application-patch.yaml`

```yaml
- op: replace
  path: /metadata/name
  value: APPLICATION
- op: replace
  path: /spec/description
  value: "APPLICATION"
- op: replace
  path: /spec/displayName
  value: "APPLICATION"
```

`component-patch.yaml`

The base Component already requests Pipelines-as-Code (`configure-pac`, `git-provider: github`). Keep those annotations. The `remove` op drops the base private-image default so the ImageRepository can be public.

```yaml
- op: replace
  path: /metadata/name
  value: COMPONENT
- op: replace
  path: /spec/componentName
  value: COMPONENT
- op: replace
  path: /spec/application
  value: APPLICATION
- op: replace
  path: /spec/source/git/url
  value: GIT_HTTPS_URL
- op: replace
  path: /spec/source/git/dockerfileUrl
  value: "DOCKERFILE"
- op: replace
  path: /spec/source/git/revision
  value: BRANCH
- op: replace
  path: /metadata/annotations/build.appstudio.openshift.io~1pipeline
  value: '{"name":"docker-build-multi-platform-oci-ta","bundle":"latest"}'
- op: remove
  path: /metadata/annotations/image.redhat.com~1generate
```

`image-repository.yaml`

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ImageRepository
metadata:
  annotations:
    image-controller.appstudio.redhat.com/update-component-image: "true"
  name: imagerepository-for-APPLICATION-COMPONENT
  labels:
    appstudio.redhat.com/application: APPLICATION
    appstudio.redhat.com/component: COMPONENT
spec:
  image:
    name: rosa-tenant/QUAY_REPO
    visibility: public
  notifications:
    - config:
        url: https://bombino.api.redhat.com/v1/sbom/quay/push
      event: repo_push
      method: webhook
      title: SBOM-event-to-Bombino
```

`integrationtestscenario-patch.yaml`

```yaml
- op: replace
  path: /metadata/name
  value: COMPONENT-BRANCH-enterprise-contract
- op: replace
  path: /spec/application
  value: APPLICATION
- op: replace
  path: /spec/contexts
  value:
    - description: Component testing
      name: component
- op: add
  path: /spec/params/-
  value:
    name: SINGLE_COMPONENT
    value: "true"
```

`releaseplan-patch.yaml`

One ReleasePlan per application. The base plan already targets `rhtap-releng-tenant` with admission `rosa` and standing attribution. Do not add another plan for later images.

```yaml
- op: replace
  path: /metadata/name
  value: APPLICATION-releaseplan
- op: replace
  path: /spec/application
  value: APPLICATION
```

## Style B — another image on an existing application

No Application. No ReleasePlan.

`kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - component.yaml
  - image-repository.yaml
  - integrationtestscenario.yaml
```

`component.yaml`

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: COMPONENT
  annotations:
    build.appstudio.openshift.io/pipeline: '{"name":"docker-build-multi-platform-oci-ta","bundle":"latest"}'
spec:
  componentName: COMPONENT
  application: APPLICATION
  source:
    git:
      url: GIT_HTTPS_URL
      context: .
      dockerfileUrl: DOCKERFILE
      revision: BRANCH
```

Add `build.appstudio.openshift.io/request: configure-pac` under `annotations` only when this GitHub repo has no Konflux component yet and Style A was not used.

`image-repository.yaml` — same as Style A.

`integrationtestscenario.yaml`

```yaml
apiVersion: appstudio.redhat.com/v1beta2
kind: IntegrationTestScenario
metadata:
  name: COMPONENT-BRANCH-enterprise-contract
spec:
  application: APPLICATION
  contexts:
    - description: Component testing
      name: component
  params:
    - name: POLICY_CONFIGURATION
      value: rhtap-releng-tenant/app-interface-standard
    - name: SINGLE_COMPONENT
      value: "true"
  resolverRef:
    params:
      - name: url
        value: https://github.com/konflux-ci/build-definitions
      - name: revision
        value: main
      - name: pathInRepo
        value: pipelines/enterprise-contract.yaml
    resolver: git
```

## openshift/release `_prowconfig.yaml`

Path: `core-services/prow/02_config/openshift-online/<repo>/_prowconfig.yaml`.

Use this only when that file does not already exist. Drop `ci/prow/...` lines that do not match jobs the repo already runs. Add a Konflux context only for a pipeline with no `pathChanged()` filter.

```yaml
branch-protection:
  orgs:
    openshift-online:
      repos:
        REPO:
          branches:
            BRANCH:
              protect: true
              required_status_checks:
                contexts:
                  - Konflux kflux-prd-rh02 / COMPONENT-on-pull-request
tide:
  queries:
    - author: dependabot[bot]
      labels:
        - approved
        - lgtm
      missingLabels:
        - do-not-merge/hold
        - do-not-merge/invalid-owners-file
        - do-not-merge/work-in-progress
      repos:
        - openshift-online/REPO
    - author: red-hat-konflux-kflux-prd-rh02[bot]
      labels:
        - approved
        - lgtm
      missingLabels:
        - do-not-merge/hold
        - do-not-merge/invalid-owners-file
        - do-not-merge/work-in-progress
      repos:
        - openshift-online/REPO
    - author: redhat-chai-bot
      labels:
        - approved
        - lgtm
      missingLabels:
        - do-not-merge/hold
        - do-not-merge/invalid-owners-file
        - do-not-merge/work-in-progress
      repos:
        - openshift-online/REPO
    - labels:
        - approved
        - jira/valid-reference
        - lgtm
      missingLabels:
        - backports/unvalidated-commits
        - do-not-merge/hold
        - do-not-merge/invalid-owners-file
        - do-not-merge/work-in-progress
        - jira/invalid-bug
      repos:
        - openshift-online/REPO
```

When the file exists, append the Konflux context and the `red-hat-konflux-kflux-prd-rh02[bot]` query if that repo is absent from Tide. Leave the other queries as they are.

## `docs/konflux.md` in the component repo

```markdown
# Konflux

Container images build on Konflux (`rosa-tenant` / `kflux-prd-rh02`).

| Component   | Containerfile | Quay image                                            |
| ----------- | ------------- | ----------------------------------------------------- |
| `COMPONENT` | `DOCKERFILE`  | `quay.io/redhat-user-workloads/rosa-tenant/QUAY_REPO` |

Application: `APPLICATION` ([Konflux UI](https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/rosa-tenant/applications/APPLICATION/activity))

| PipelineRun                 | Trigger                   |
| --------------------------- | ------------------------- |
| `COMPONENT-on-pull-request` | Pull requests to `BRANCH` |
| `COMPONENT-on-push`         | Push to `BRANCH`          |

Onboarding checklist and Quay tag rules: [HyperFleet Konflux onboarding](https://github.com/openshift-online/rosa-hyperfleet/blob/main/docs/konflux-onboarding.md).

Pin `:<full-git-sha>` from a green on-push build. PR tags `on-pr-<sha>` expire after 5 days.
```

For a path-filtered component, replace the trigger cell with the paths in the CEL expression.
