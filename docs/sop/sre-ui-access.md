# SRE UI Access

Browser-based access to Grafana, ArgoCD, Prometheus, and Thanos via the SRE UI ALB.

## Prerequisites

1. **Red Hat VPN** — required for the corporate proxy to function.
2. **Browser proxy configured** — traffic to SRE UI domains must route through
   `squid.corp.redhat.com:3128`. See
   [Browser proxy configuration](#browser-proxy-configuration) below for
   environment-specific wildcards.
3. **Red Hat employee account** — authentication via Red Hat SSO
   (`auth.stage.redhat.com`).

## Integration Environment

### URLs

| Tool       | URL                                                     | Purpose                      |
| ---------- | ------------------------------------------------------- | ---------------------------- |
| Grafana    | https://grafana.sre.us-east-1.int0.rosa.devshift.org    | Metrics dashboards and logs  |
| ArgoCD     | https://argocd.sre.us-east-1.int0.rosa.devshift.org     | GitOps application status    |
| Prometheus | https://prometheus.sre.us-east-1.int0.rosa.devshift.org | Raw metric queries (RC)      |
| Thanos     | https://thanos.sre.us-east-1.int0.rosa.devshift.org     | Aggregated metrics (RC + MC) |

**Proxy wildcard:** `*.sre.us-east-1.int0.rosa.devshift.org`

## Stage Environment

### URLs

| Tool       | URL                                                     | Purpose                      |
| ---------- | ------------------------------------------------------- | ---------------------------- |
| Grafana    | https://grafana.sre.us-east-1.stg0.rosa.devshift.org    | Metrics dashboards and logs  |
| ArgoCD     | https://argocd.sre.us-east-1.stg0.rosa.devshift.org     | GitOps application status    |
| Prometheus | https://prometheus.sre.us-east-1.stg0.rosa.devshift.org | Raw metric queries (RC)      |
| Thanos     | https://thanos.sre.us-east-1.stg0.rosa.devshift.org     | Aggregated metrics (RC + MC) |

**Proxy wildcard:** `*.sre.us-east-1.stg0.rosa.devshift.org`

## Authentication

On first visit the browser redirects to Red Hat SSO. Authenticate with your Red
Hat credentials or via Kerberos SSO. Sessions last 8 hours.

## Access levels

| Tool       | Access level after login |
| ---------- | ------------------------ |
| Grafana    | Read-only (Viewer)       |
| ArgoCD     | Read-only                |
| Prometheus | Read-only                |
| Thanos     | Read-only                |

## Browser proxy configuration

The ALB only accepts traffic from Red Hat corporate proxy egress IPs. Configure
your browser to proxy SRE UI domains through `squid.corp.redhat.com:3128`. The
proxy is only reachable from the Red Hat VPN.

### Chrome — ZeroOmega

Install [ZeroOmega](https://chromewebstore.google.com/detail/proxy-switchyomega-3-zero/pfnededegaaopdmhkdmcofjmoldfiped)
from the Chrome Web Store.

1. Open the ZeroOmega options panel.
2. Create a new proxy profile named **seaplane-sre**:
   - Protocol: `HTTP`
   - Server: `squid.corp.redhat.com`
   - Port: `3128`
3. In the **Auto Switch** profile add conditions for each environment:
   - **Integration:**
     - Condition type: `Host wildcard`
     - Condition details: `*.sre.us-east-1.int0.rosa.devshift.org`
     - Profile: `seaplane-sre`
   - **Stage:**
     - Condition type: `Host wildcard`
     - Condition details: `*.sre.us-east-1.stg0.rosa.devshift.org`
     - Profile: `seaplane-sre`
4. Click **Apply changes** and activate the **Auto Switch** profile.

### Firefox — FoxyProxy

Install [FoxyProxy](https://addons.mozilla.org/firefox/addon/foxyproxy-standard/).

1. Open FoxyProxy options → **Proxies** → **Add**.
2. Configure the proxy:
   - Title: `seaplane-sre`
   - Type: `HTTP`
   - Hostname: `squid.corp.redhat.com`
   - Port: `3128`
3. Under **URL Patterns** add both environment wildcards:
   - **Integration:** Pattern: `*.sre.us-east-1.int0.rosa.devshift.org`, Type: `Wildcard`
   - **Stage:** Pattern: `*.sre.us-east-1.stg0.rosa.devshift.org`, Type: `Wildcard`
4. Save and enable FoxyProxy.

## Troubleshooting

**500 after SSO redirect** — The AWS Application LB cannot reach the OIDC Provider (auth.stage.redhat.com) to get the SSO token.

**503 Service Unavailable** — The target group has no healthy targets. Check the cluster TargetGroupBindings and pod health on the RC cluster (make int-bastion-rc).

**Proxy connection refused** — You are not connected to the Red Hat VPN.
Connect to VPN and retry.
