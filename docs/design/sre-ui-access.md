# ROSA Seaplane (v2): SRE UI Access

**Last Updated Date**: 2026-07-03

## Summary

This document proposes replacing the current SSM + kubectl port-forward access to SRE UIs (Grafana, ArgoCD, Thanos Querier, Thanos Ruler, Alertmanager, Prometheus, ZOA Console) with an AWS ALB using native OIDC authentication (RH SSO / EmployeeIDP). The approach reuses the existing TargetGroupBinding pattern (proven for Platform API and RHOBS), requires no Kubernetes-level changes, and provides an incremental hardening path (OIDC → proxy IP restriction) without requiring VPN infrastructure.

## Context

- **Problem Statement**: SRE UIs are currently accessible only via SSM + kubectl port-forwarding through ECS Fargate bastions. This approach is flaky (sessions drop, chains break), incompatible with Zero Operator Access (no audit trail, no identity propagation), and not production-ready (relies on temporary bastion infrastructure).
- **Constraints**:
  - No VPN connectivity exists between RH network and Seaplane AWS VPCs today
  - EKS clusters are fully private (`endpoint_public_access = false`)
  - Services must stay as `ClusterIP` (no `LoadBalancer` type, no Ingress controller)
  - Same pattern must work across ephemeral, integration, stage, and production environments
  - Solution must be compatible with Zero Operator Access model
- **Assumptions**:
  - RH SSO (EmployeeIDP) supports OIDC with ALB integration
  - TargetGroupBinding CRDs are available in all clusters (EKS Auto Mode)
  - The existing `api-gateway` and `rhobs-api-gateway` Terraform patterns can be reused
  - All SRE services expose HTTP health check endpoints

## Alternatives Considered

### 1. Current: SSM + kubectl port-forward

**How it works**: SRE starts an ECS Fargate bastion via SSM, then chains kubectl port-forward commands to reach individual services.

| Aspect           | Assessment                                                                                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reliability      | Poor — SSM sessions drop, port-forward chains break                                                                                                                    |
| Identity/Audit   | None — SSM session identity only                                                                                                                                       |
| Production-ready | No — bastion infrastructure is temporary                                                                                                                               |
| ZOA compatible   | No — requires VPN + kinit + SSM port-forward scripts; no OIDC identity propagation to services                                                                         |
| UX               | Poor — no bookmarkable URLs; must run `make ephemeral-portforwarding` per cluster, then navigate to `localhost:<port>` per service. Cannot share links with teammates. |

**Verdict**: Unacceptable for production. Adequate only as a temporary workaround during early development.

### 2. Kubernetes Ingress Controller

**How it works**: Deploy an ingress controller (nginx, traefik, or AWS ALB Controller) inside the cluster. Create Ingress resources for each service.

| Aspect                             | Assessment                                                                                                                   |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Maturity                           | Proven in traditional Kubernetes                                                                                             |
| Consistency with existing patterns | Poor — we don't use ingress controllers anywhere; Platform API and RHOBS use Terraform-managed ALBs with TargetGroupBindings |
| OIDC support                       | Requires oauth2-proxy sidecar or external identity-aware proxy                                                               |
| Infrastructure ownership           | Mixed — Kubernetes creates/manages the ALB, Terraform doesn't own it                                                         |
| Lifecycle                          | Tied to ArgoCD sync; infra changes and app changes coupled                                                                   |
| Sidecar requirement                | Needs oauth2-proxy sidecar in each service's Helm chart for OIDC — intrusive changes to upstream charts                      |

**Verdict**: Not recommended. Introduces a new pattern inconsistent with existing infrastructure. Blurs Terraform/Kubernetes ownership boundaries.

### 3. AWS ALB + OIDC (Recommended)

**How it works**: Terraform creates a dedicated ALB with wildcard TLS certificate, host-based listener rules, and `authenticate-oidc` actions. Each rule authenticates via RH SSO before forwarding to a target group. Helm charts add `TargetGroupBinding` CRDs to wire pod IPs into target groups.

| Aspect                   | Assessment                                                                               |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| Consistency              | Follows existing `api-gateway` and `rhobs-api-gateway` patterns exactly                  |
| OIDC support             | Native ALB `authenticate-oidc` action — no proxy deployments needed                      |
| Infrastructure ownership | Clear — Terraform owns ALB/TG/DNS, Helm owns TargetGroupBindings                         |
| Kubernetes changes       | None — services stay ClusterIP                                                           |
| Incremental hardening    | SG can be tightened to proxy IPs (Phase 2) without ALB changes; VPN-ready if ever needed |

**Verdict**: Recommended. Reuses proven patterns, native OIDC, clean separation of concerns.

### 4. CloudFront + Cognito / Lambda@Edge

**How it works**: CloudFront distribution with either AWS Cognito (federated to RH SSO) or Lambda@Edge for OIDC authentication, origin pointing to internal ALB.

| Aspect              | Assessment                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| Global distribution | Unnecessary — SRE UIs are regional, not customer-facing                                          |
| Cost                | Higher — CloudFront + Cognito user pool (or Lambda invocations per request)                      |
| Complexity          | Cognito federation to RH SSO adds another identity layer to manage. Lambda@Edge has cold starts. |
| Consistency         | Not aligned with existing patterns (no other service uses CloudFront/Cognito)                    |

**Note**: Cognito can also be used directly with ALB (without CloudFront) — ALB supports Cognito as an authentication action. However, Cognito adds an intermediate identity provider between the ALB and RH SSO, whereas ALB `authenticate-oidc` talks directly to RH SSO without a middleman. Cognito is more useful when you need user pools, MFA, or multiple identity providers — none of which apply here.

**Verdict**: Not recommended. Both CloudFront+Cognito and CloudFront+Lambda@Edge add services and complexity for a problem that ALB-native `authenticate-oidc` already solves directly. The ALB approach is simpler, cheaper, and consistent with our existing patterns.

## Design Rationale

### Phase 1 (initial): Public ALB + OIDC

Deploy a public (internet-facing) ALB with `authenticate-oidc` actions on all listener rules. Security group allows `0.0.0.0/0` on port 443. Protection is identity-only (RH SSO restricts to authenticated Red Hat employees with password + MFA).

**Why start here**: No infrastructure dependencies. Immediately solves flakiness, provides identity/audit, and works across all environments without VPN.

**If Phase 2 cannot be achieved** (proxy IPs unavailable or unstable), consider adding AWS WAF with rate-limiting rules on the ALB as extra protection against automated attacks on the OIDC endpoint.

### Phase 2 (hardening): Public ALB + OIDC + RH Proxy restriction

ALB remains internet-facing, but the security group is restricted to the public egress IPs of Red Hat's corporate proxy. Engineers configure their browser with a PAC file that routes SRE UI hostnames through the proxy.

**Why this is attractive**:

- No RH IT dependency for network infrastructure — uses existing corporate proxy
- No VPN to build — ALB stays public, just SG change + PAC file distribution
- Defense in depth — network restriction (proxy IPs) + identity (OIDC)
- Same pattern already used at RH for accessing restricted internal services via browser proxy
- Small number of IPs to whitelist (one per RH datacenter)

**PAC file example**:

```javascript
function FindProxyForURL(url, host) {
  if (shExpMatch(host, "*.sre.*.rosa.devshift.org")) {
    return "PROXY <rh-corporate-proxy>";
  }
  if (shExpMatch(host, "*.sre.*.rosa.redhat.com")) {
    return "PROXY <rh-corporate-proxy>";
  }
  return "DIRECT";
}
```

**Open item**: We need the proxy egress IPs to be provided by RH IT in an automated way (single source of truth) that can be embedded into our Terraform configuration. If a fully automated sync isn't available, we need at minimum a known place to check so we can update easily when IPs change.

### Phase 3 (future, if required): Private ALB + VPN

If full VPN connectivity between RH network and Seaplane VPCs becomes necessary, int/stage/prod environments could migrate to a private (internal) ALB. The transition would be a variable change: `internal = true`, `subnet_ids = private subnets`.

However, we'd prefer to avoid this path if possible:

- Requires RH IT coordination for Site-to-Site VPN or Transit Gateway peering
- Adds complex manual configuration to our automated pipelines
- Network interconnection with RH IT networks is operationally heavy

Given that this is just browser access to SRE UIs already protected by RH SSO (OIDC), and Phase 2 already restricts to specific proxy IPs, full VPN connectivity may not be justified for this use case. We will evaluate if Phase 3 is needed based on security requirements, but Phase 2 should provide sufficient defense in depth.

This is the same networking problem as ZOA boundary break-glass access to private EKS. If VPN infrastructure is ever built for that purpose, SRE UI access would ride on the same connectivity.

## Architecture

### ALB Routing Design

One ALB per regional cluster with host-based listener rules. Each rule has two actions: `authenticate-oidc` (redirect to RH SSO if unauthenticated) then `forward` (to the service's target group).

```
ALB (HTTPS:443, wildcard cert: *.sre.<regional_domain>)
├── grafana.sre.*       → authenticate-oidc → grafana TG (:3000)
├── argocd.sre.*        → authenticate-oidc → argocd TG (:8080)
├── thanos-querier.sre.* → authenticate-oidc → thanos-query TG (:9090)
├── thanos-ruler.sre.*  → authenticate-oidc → thanos-ruler TG (:9090)
├── alertmanager.sre.*  → authenticate-oidc → alertmanager TG (:9093)
├── zoa.sre.*           → authenticate-oidc → zoa-console TG (:8080)
├── prometheus.sre.*    → authenticate-oidc → prometheus TG (:9090)
└── Default             → fixed-response 404
```

### DNS Scheme

Uses the existing regional zone hierarchy:

```
<service>.sre.<region>.<env>.<domain>
```

Examples:

| Environment | Service        | FQDN                                                  |
| ----------- | -------------- | ----------------------------------------------------- |
| Integration | Grafana        | `grafana.sre.us-east-1.int0.rosa.devshift.org`        |
| Integration | ArgoCD         | `argocd.sre.us-east-1.int0.rosa.devshift.org`         |
| Integration | Thanos Querier | `thanos-querier.sre.us-east-1.int0.rosa.devshift.org` |
| Integration | Alertmanager   | `alertmanager.sre.us-east-1.int0.rosa.devshift.org`   |
| Integration | Thanos Ruler   | `thanos-ruler.sre.us-east-1.int0.rosa.devshift.org`   |
| Integration | ZOA Console    | `zoa.sre.us-east-1.int0.rosa.devshift.org`            |
| Integration | Prometheus     | `prometheus.sre.us-east-1.int0.rosa.devshift.org`     |
| Stage       | Grafana        | `grafana.sre.us-east-1.stg0.rosa.devshift.org`        |
| Stage       | ArgoCD         | `argocd.sre.us-east-1.stg0.rosa.devshift.org`         |
| Stage       | Prometheus     | `prometheus.sre.us-east-1.stg0.rosa.devshift.org`     |
| Stage       | Thanos         | `thanos.sre.us-east-1.stg0.rosa.devshift.org`         |
| Ephemeral   | Grafana        | `grafana.sre.us-east-1.eph-7e3884.rosa.devshift.org`  |
| MC (int)    | ArgoCD         | `argocd.sre.mc01.us-east-1.int0.rosa.devshift.org`    |
| Production  | Grafana        | `grafana.sre.us-east-1.prod.rosa.redhat.com`          |

**TLS**: Wildcard ACM certificate `*.sre.<region>.<env>.<domain>`, DNS-validated via Route53. One certificate covers all SRE services.

**Note**: In Terraform, the composed `<region>.<env>.<domain>` string is passed as `var.regional_domain` (e.g., `us-east-1.int0.rosa.devshift.org` for RC, `mc01.us-east-1.int0.rosa.devshift.org` for MC).

### Service Mapping

| Service        | K8s Service                          | Namespace      | Port | Health Check  | Description                                           | OIDC                                          |
| -------------- | ------------------------------------ | -------------- | ---- | ------------- | ----------------------------------------------------- | --------------------------------------------- |
| Grafana        | `grafana`                            | `grafana`      | 3000 | `/api/health` | Dashboards for metrics, logs (K8s and AWS infra)      | Native OIDC support; ALB OIDC also works      |
| ArgoCD         | `argocd-server`                      | `argocd`       | 8080 | `/healthz`    | GitOps deployment UI (app status, diff, logs)         | Native OIDC support; use HTTP port behind ALB |
| Thanos Querier | `thanos-query-frontend-thanos-query` | `thanos`       | 9090 | `/-/ready`    | Consolidated PromQL queries across all RC/MCs         | No native auth — ALB OIDC required            |
| Thanos Ruler   | `thanos-ruler-thanos-ruler`          | `thanos`       | 9090 | `/-/ready`    | Alerting rule evaluation and recording rules          | No native auth — ALB OIDC required            |
| Alertmanager   | `monitoring-alertmanager`            | `monitoring`   | 9093 | `/-/ready`    | Alert routing, silencing, and inhibition              | No native auth — ALB OIDC required            |
| ZOA Console    | `zoa-console`                        | `platform-api` | 8080 | `/healthz`    | Trusted action audit and executions                   | No native auth — ALB OIDC required            |
| Prometheus     | `prometheus-server`                  | `monitoring`   | 9090 | `/-/ready`    | Local scrape data (remote-writes to Thanos); fallback | No native auth — ALB OIDC required            |

### Management Cluster Services

Same architecture deployed **per MC account**, exposing ArgoCD and Prometheus:

- Same Terraform module instantiated in each MC account
- DNS: `<service>.sre.<mc-name>.<region>.<env>.<domain>`
- Wildcard cert: `*.sre.<mc-name>.<region>.<env>.<domain>`
- ALB lives in the MC VPC (no cross-VPC connectivity needed)
- Can be extended to more MC services later by adding entries to the services map

## OIDC Configuration

| Parameter              | Value                                             |
| ---------------------- | ------------------------------------------------- |
| Issuer                 | `https://auth.redhat.com/auth/realms/EmployeeIDP` |
| Authorization Endpoint | `<issuer>/protocol/openid-connect/auth`           |
| Token Endpoint         | `<issuer>/protocol/openid-connect/token`          |
| UserInfo Endpoint      | `<issuer>/protocol/openid-connect/userinfo`       |
| Scope                  | `openid email profile`                            |
| Session Timeout        | 28800s (8 hours)                                  |
| Cookie Name            | `AWSELBAuthSessionCookie`                         |
| On Unauthenticated     | `authenticate` (redirect to login)                |

**Redirect URI pattern**: `https://<host>/oauth2/idpresponse`

**Identity headers forwarded to services** (after authentication):

| Header                    | Content                              |
| ------------------------- | ------------------------------------ |
| `x-amzn-oidc-accesstoken` | Access token from RH SSO             |
| `x-amzn-oidc-identity`    | User's email (from `sub` claim)      |
| `x-amzn-oidc-data`        | JWT with full claims (signed by ALB) |

## Consequences

### Positive

- Stable, reliable access — AWS-managed ALB instead of SSM chains
- Identity and audit — OIDC identity + ALB access logs for every request
- ZOA compatible — browser-based with identity propagation
- Production-ready — same pattern used for customer-facing Platform API
- No Kubernetes changes — services stay as ClusterIP
- Incremental hardening — can tighten SG to proxy IPs (Phase 2) without architectural changes
- Scalable — adding a new service is one Terraform entry + one Helm template

### Negative

- OIDC client management — need to register/maintain client with RH SSO
- PAC file distribution (Phase 2) — manual browser configuration for engineers
- Proxy IP tracking (Phase 2) — need to keep SG in sync if proxy IPs change
- Phase 3 dependency — full VPN would require RH IT coordination (complex, prefer to avoid unless required)

### Risks

- **EmployeeIDP redirect URI support**: If wildcard redirect URIs are not supported, ephemeral environments may need a workaround (single client with enumerated URIs, or per-env client registration)
- **Proxy IP stability**: If IPs change frequently without notification, Phase 2 could break access

## Cross-Cutting Concerns

- **Monitoring**: ALB metrics (4xx/5xx, target health) integrated into existing CloudWatch/Grafana dashboards. The ALB namespace will need to be added to the CloudWatch Exporter scrape configuration (YACE) to surface metrics in Prometheus/Grafana.
- **Cost**: One ALB per regional cluster (~$20/month + LCU charges). Minimal compared to existing infrastructure.
- **Observability**: ALB access logs to S3 provide full request audit trail (who accessed what, when)
- **Disaster recovery**: ALB is regional AWS-managed. If the region is down, SRE UIs are irrelevant anyway.
- **ArgoCD RBAC**: ArgoCD's native OIDC is read-only by default. Write access (sync, rollback) can be enabled per-environment via Helm values templating — e.g., read-write in ephemeral, read-only in production.
- **Grafana roles**: Grafana defaults to read-only (Viewer). Write access (Editor/Admin) can be overridden per-environment via Helm values templating, same pattern as ArgoCD.

## Open Questions

1. **OIDC client registration**: Who owns the RH SSO client? Does EmployeeIDP support wildcard redirect URIs for ephemeral environments, or do we need a single static client?
2. **Proxy IP source of truth**: What's the canonical, automatable source for proxy egress IPs? How do we keep our SG in sync?

## Next Steps

- [ ] Validate OIDC client registration with RH SSO / EmployeeIDP team
- [ ] Confirm proxy IP source of truth and update mechanism with RH IT
- [ ] Implement `terraform/modules/sre-ui-alb/` module
- [ ] Add TargetGroupBinding templates to service Helm charts
- [ ] Deploy Phase 1 in ephemeral environment and validate
- [ ] Distribute PAC file and deploy Phase 2 (proxy restriction) for integration
- [ ] Evaluate Phase 3 (VPN) only if security requirements demand it beyond Phase 2
