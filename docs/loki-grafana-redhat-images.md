# Loki and Grafana Red Hat images (ROSAENG-67993)

RH Logging is LokiStack + Cluster Logging Operator. Those operators are OpenShift-only and stay rejected on EKS ([logging platform](design/logging-platform.md)). This pin uses catalog **operand images** on the charts already running on the regional cluster.

## Loki — pin

Keep [grafana/loki](https://grafana.github.io/helm-charts) **7.0.0** (vendored). Do not install the Loki Operator.

| Source                                                                                                                                         | Loki binary          |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| Wrapper chart `appVersion` / chart default image                                                                                               | **3.6.7**            |
| `logging-loki-rhel9:v6.0.x` (card example)                                                                                                     | **3.1.0**            |
| `logging-loki-rhel9:v6.4.6` (same z-stream as Vector)                                                                                          | S3 trailer bug; skip |
| [`logging-loki-rhel9:v6.4.7`](https://catalog.redhat.com/en/software/containers/openshift-logging/logging-loki-rhel9/64479926a759a6e51ef79b12) | **3.7**              |

v6.0.16 is not a tag swap onto chart 7.0.0. v6.4.7 is the Logging 6.4 line (same product as Vector `vector-rhel9:v6.4.6`) without the 6.4.6 S3 upload bug. Chart args remain `-config.file` / `-target=`. Storage stays classic S3 (`use_thanos_objstore` off).

The catalog image has no ENTRYPOINT/CMD. Set `loki.loki.command: /usr/bin/loki`. grafana/loki 7.0.0 wires that on distributor, ingester, query-frontend, and compactor, but not querier or index-gateway. Same pattern as cert-manager: vendor the chart in `loki-chart/`, render with Kustomize `helmCharts`, and strategic-merge `command: [/usr/bin/loki]` on those two workloads. `make helm-deps CHART=argocd/config/regional-cluster/loki/loki-chart` refreshes the lock and tgz.

Manifest-list digest (v6.4.7): `sha256:90ab304b12402d6759330a338f7b26fcf9ac7ec4d601fcab2582dca99111544b`.

## Grafana — Red Hat hardened image

| Source                       | Grafana                                                        |
| ---------------------------- | -------------------------------------------------------------- |
| `rhel10/grafana:10.3`        | **12.4.3** (RHEL 10 Grafana package source; verify image SBOM) |
| `openshift4/ose-grafana`     | Deprecated CMO image (catalog v4.11 stream, Grafana ~8.3)      |
| Previous `grafana-oss` image | **11.4.0**                                                     |

Use `registry.redhat.io/rhel10/grafana:10.3`, pinned to manifest-list digest `sha256:172af6db978bb10c8301f546025a9a5ace06c44177d2d23614f4caecd0887957`. The `10.3` tag is the RHEL stream, not Grafana's version. Red Hat's CentOS Stream Grafana package source specifies 12.4.3, but verify the pinned image's SBOM before rollout. `openshift4/ose-grafana` is deprecated and is not the replacement. This is a major-version upgrade from 11.4; validate startup, security context, dashboards, datasources, and provisioning against the exact image. The existing k8s-sidecar remains a separate third-party image.

## Pull secret

`registry.redhat.io` needs a namespace-local `pull-secret` from SSM `/infra/pull-secret`. Loki, Vector, and Grafana each create the ExternalSecret in their own namespace.
