# platform-api Argo CD wrapper chart

This chart creates the `seaplane-api` Argo CD Application. The application
loads its deployment chart from `seaplane-api/charts` in
[`rosa-seaplane-api`](https://github.com/openshift-online/rosa-seaplane-api),
so the chart is maintained alongside the API it deploys.

The child chart uses separate registry, repository, and tag values. An empty
registry resolves to the SSM-backed ECR account; existing full `IMAGE_REPO`
Quay overrides are split into registry and repository for compatibility.

The component-chart values remain in this wrapper's `values.yaml` and are
passed through to the child chart. Environment-specific overrides in
`rosa-seaplane` continue to use the existing `platformApi` and `global` keys.
