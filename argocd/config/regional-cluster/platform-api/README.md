# platform-api Argo CD wrapper chart

This chart creates the `platform-api` Argo CD Application. The application
loads its deployment chart from `platform-api/charts` in
[`rosa-seaplane-api`](https://github.com/openshift-online/rosa-seaplane-api),
so the chart is maintained alongside the API it deploys.

The component-chart values remain in this wrapper's `values.yaml` and are
passed through to the child chart. Environment-specific overrides in
`rosa-seaplane` continue to use the existing `platformApi` and `global` keys.
