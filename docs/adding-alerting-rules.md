# Adding Alerting Rules

This guide explains how to add a new PrometheusRule to the platform. All alerting and recording rules are evaluated by Thanos Ruler against Thanos Query, which has access to metrics from both the Regional Cluster and all Management Clusters in the region.

## Where to Add Rules

All platform rules live in the `alerting-rules` Helm chart:

```text
argocd/config/regional-cluster/alerting-rules/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── hcp-sla.yaml      # example: HCP availability SLA rules
    └── zoa.yaml          # ZOA Lambda/EMF alerts (YACE gauges, not rate())
```

Each template renders a `PrometheusRule` CR (`monitoring.coreos.com/v1`). You can group related rules in a single file or create separate files — one file per logical concern is the convention.

## PrometheusRule CR Structure

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-rules
  namespace: thanos
  labels:
    app.kubernetes.io/name: alerting-rules # required — ThanosRuler ruleConfigSelector
    app.kubernetes.io/managed-by: Helm
    operator.thanos.io/prometheus-rule: "true" # required — thanos-operator default label
spec:
  groups:
    - name: my-recording-rules
      interval: 1m # optional, defaults to global evaluation interval
      rules:
        - record: my:metric_name
          expr: |
            some_promql_expression
          labels:
            extra_label: value

    - name: my-alerts
      rules:
        - alert: MyAlertName
          expr: |
            some_promql_expression > threshold
          for: 5m
          labels:
            severity: critical # or warning
          annotations:
            summary: Short description
            description: >-
              Longer description with template variables like
              {{ "{{" }} $labels.name {{ "}}" }}.
```

Key points:

- **namespace**: Always `thanos` — Thanos Ruler discovers rules in this namespace.
- **labels**: Two labels are **required** for Thanos Ruler to discover the PrometheusRule:
  - `app.kubernetes.io/name: alerting-rules` — matched by the ThanosRuler `ruleConfigSelector`
  - `operator.thanos.io/prometheus-rule: "true"` — the thanos-operator's default label, always merged into the selector via `BuildLabelSelectorFrom()`
  - Both must be present. Missing either one causes the operator to skip the rule (`found prometheus rule-based configmaps count=0`).
  - Also include `app.kubernetes.io/managed-by: Helm` for consistency.
- **Helm escaping**: Prometheus template expressions (`{{ $labels.name }}`) conflict with Helm's `{{ }}` syntax. Escape them as `{{ "{{" }} $labels.name {{ "}}" }}`.

## Using Helm Values

Parameterize thresholds and targets via `values.yaml` so they can be overridden per environment:

```yaml
# values.yaml
sla:
  target: 0.9995
```

```yaml
# templates/my-rules.yaml
- alert: MyBurnRateAlert
  expr: |
    error_rate > (6 * (1 - {{ .Values.sla.target }}))
```

## Error Budget Burn Rate Pattern

For SLA-based alerts, use multi-window, multi-burn-rate alerting as described in the [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/). See `templates/hcp-sla.yaml` for a working example with the HCP availability SLA.

Do not exclude install or delete in PromQL. The hyperfleet-operator silence reconciler writes Alertmanager silences for those phases, matched on `namespace` and `name`. `HCPInstallTimeout15m` stays exempt during install. New SLA alerts must keep `namespace` and `name` so those silences match, and `cluster` for routing and dashboards.

## Testing with promtool

### Writing Tests

Create a test file in `ci/promtool-test/` following the [promtool unit testing format](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/):

```yaml
evaluation_interval: 1m

rule_files:
  - rules.yaml # populated by ci/promtool-test.sh from Helm output

tests:
  - interval: 1m
    input_series:
      - series: 'my_metric{name="test", namespace="test-ns"}'
        values: "1 1 1 0 0 0" # available, then unavailable
    alert_rule_test:
      - eval_time: 5m
        alertname: MyAlertName
        exp_alerts: []
```

### Running Tests Locally

```bash
./ci/promtool-test.sh
```

This script:

1. Renders the `alerting-rules` chart via `helm template`
2. Extracts the PrometheusRule `.spec` into a standalone rules file using `yq`
3. Runs `promtool check rules` to validate syntax
4. Runs `promtool test rules` against test files in `ci/promtool-test/`

Tests also run in CI as part of the unit test suite.

## Verification in Ephemeral Environment

After deploying to an ephemeral environment:

1. Confirm ThanosRuler pods are running: `kubectl get pods -n thanos -l app.kubernetes.io/name=thanos-ruler`
2. Query the recording rule via Thanos Query to verify it produces data
3. Check alert state via Thanos Query UI — new alerts should be in `inactive` state for healthy clusters
4. Verify `helm lint argocd/config/regional-cluster/alerting-rules/` passes

## Naming Conventions

- **Recording rules**: Use colons as namespace separators — `<domain>:<metric_name>` (e.g., `hcp:hostedcluster_available`)
- **Alerts**: PascalCase, descriptive — `HCPAvailabilityErrorBudgetFastBurn`
- **Template files**: kebab-case matching the logical concern — `hcp-sla.yaml`
- **Rule groups**: kebab-case — `hcp-availability-recording`, `hcp-availability-alerts`
