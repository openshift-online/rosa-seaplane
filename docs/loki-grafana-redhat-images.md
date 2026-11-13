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

The catalog image has no ENTRYPOINT/CMD. Set `loki.loki.command: /usr/bin/loki`. grafana/loki 7.0.0 wires that on distributor, ingester, query-frontend, and compactor, but not querier or index-gateway. `ci/patch-loki-command-templates.py` adds the same hook; `make helm-deps CHART=argocd/config/regional-cluster/loki` re-applies it after a fetch.

Manifest-list digest (v6.4.7): `sha256:90ab304b12402d6759330a338f7b26fcf9ac7ec4d601fcab2582dca99111544b`.

## Grafana — do not pin ose-grafana

| Source                   | Grafana                                                   |
| ------------------------ | --------------------------------------------------------- |
| Wrapper `grafana-oss`    | **11.4.0**                                                |
| `openshift4/ose-grafana` | Deprecated CMO image (catalog v4.11 stream, Grafana ~8.3) |

ose-grafana is not Grafana 11. Dashboards, sidecar provisioning, and `grafana.ini` assume 11.4. Keep `docker.io/grafana/grafana-oss:11.4.0`. The k8s-sidecar has no RH catalog equivalent. A Grafana 11 trusted build is Konflux (type 3), not this card.

## Pull secret

`registry.redhat.io` needs `pull-secret` in `loki` from SSM `/infra/pull-secret` (same ExternalSecret as Vector).
