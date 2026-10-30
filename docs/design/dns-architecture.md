# DNS Architecture for ROSA Seaplane

**Last Updated Date**: 2026-05-11

## Summary

ROSA Seaplane uses a hierarchical DNS architecture built on AWS Route 53, with DNSSEC throughout, that distributes records across per-region zone shards to scale beyond 10k records. Each regional deployment is uniquely identified by a `deployment_name` — which defaults to the AWS region name but can be suffixed to support multiple deployments per region within the same environment.

## Context

- **Problem Statement**: The current ROSA HCP architecture uses a single HostedZone containing records from all regions, which cannot scale beyond 10,000 records. Ingress certificates require ACME challenges through customer account HostedZones, which can fail due to misconfigurations or permission issues. Additionally, the platform needs a deployment identifier that supports multiple deployments of the same AWS region within a single environment.
- **Constraints**:
  - Route 53 limits: 500 HostedZones per account, 10,000 records per HostedZone
  - FedRAMP requires DNSSEC to be enabled and verified
  - XCMSTRAT-214 requires support for long cluster names (up to 54 chars) and customizable domain prefixes
  - Maximum FQDN length is 255 characters
- **Assumptions**:
  - We expect 50–100 regions total in production
  - Each cluster consumes ~4–8 DNS records
  - For integration, we use `int0.rosa.devshift.net` and for staging we use `stg0.rosa.devshift.org` instead of `rosa.openshiftapps.com`. The `int0`/`stg0` suffix keeps consistent length with the production domain.

## Design

### Deployment Naming

Each regional deployment is identified by a `deployment_name` that serves as its unique identifier within an environment. This appears in DNS names, directory structures, and ArgoCD labels.

`deployment_name` is an explicit config field (default: `"{{ aws_region }}"`). `aws_region` is always the config file stem — it is not configurable.

For the common case (one deployment per region), the default template resolves `deployment_name` to the AWS region:

```text
config/integration/
├── defaults.yaml               # deployment_name: "{{ aws_region }}"  (global default)
└── us-east-1.yaml              # deployment_name = us-east-1, aws_region = us-east-1
```

For CI/e2e runs, the ephemeral environment overrides the default to include the run's unique prefix:

```yaml
# config/ephemeral/defaults.yaml
deployment_name: "{{ aws_region }}{% if eph_prefix %}-{{ eph_prefix }}{% endif %}"
```

```text
config/ephemeral/
├── defaults.yaml               # deployment_name includes eph_prefix when set
└── us-east-1.yaml              # deployment_name = us-east-1-xg4y (with --eph-prefix xg4y)
                                # aws_region = us-east-1 (always file stem)
```

For multiple permanent deployments of the same region, a per-region config file overrides `deployment_name`:

```yaml
# config/integration/us-east-1-2.yaml
deployment_name: us-east-1-2
aws_region: us-east-1
provision_mcs:
  mc01: {}
```

### DNS Hierarchy

```text
1 -  openshiftapps.com (public zone, on Cloudflare, managed by app-interface)
2 -  └── rosa.openshiftapps.com (NS, public zone) [terraform: bootstrap-global pipeline]
3 -      └── {deployment_name}.rosa.openshiftapps.com (NS, public zone) [terraform: region provisioner pipeline]
4 -          ├── api.{deployment_name}.rosa.openshiftapps.com (A) [terraform]
5 -          └── {zone_shard}.{deployment_name}.rosa.openshiftapps.com (NS, public zone) [terraform: region provisioner pipeline]
6 -              ├── api.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (A → KAS LB / CNAME → VPCE) [MC external-dns]
7 -              ├── oauth.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (A → KAS LB / CNAME → VPCE) [MC external-dns]
8 -              ├── _acme-challenge.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (TXT) [MC cert-manager]
9 -              └── in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (NS → public zone 11) [HyperShift CPO via DNSEndpoint CR]

Zones created by HyperShift CPO in the customer account (not delegated from shard — VPC-associated for private, NS-delegated for public):

10- in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (private zone, VPC-associated) [HyperShift CPO]
    └── *.apps.in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (A → Customer Ingress) [HCP ingress operator]
11- in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (public zone, NS-delegated from shard 5) [HyperShift CPO]
    ├── *.apps.in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (A → Customer Ingress) [HCP ingress operator]
    └── _acme-challenge.apps.in.{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com (CNAME → _acme-challenge in the regional shard zone) [HyperShift CPO]

12- {cluster_alias}.hypershift.local (private zone, VPC-associated) [HyperShift CPO]
    ├── api.{cluster_alias}.hypershift.local (A → VPCE)
    └── *.apps.{cluster_alias}.hypershift.local (A → Customer Ingress)
```

### Zone Ownership

| #   | Zone / Record                                           | Owner                          | Notes                                                                                                                                                                   |
| :-- | :------------------------------------------------------ | :----------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `openshiftapps.com`                                     | app-interface                  | Top-level, exists in Cloudflare                                                                                                                                         |
| 2   | `rosa.openshiftapps.com`                                | Control-account terraform      | Commons zone, NS via app-interface                                                                                                                                      |
| 3   | `{deployment_name}.rosa.openshiftapps.com`              | Control-account terraform      | Regional zone; creates NS record in the commons zone (2)                                                                                                                |
| 4   | `api.{deployment_name}.rosa.openshiftapps.com`          | Regional pipeline              | Platform API record                                                                                                                                                     |
| 5   | `{zone_shard}.{deployment_name}.rosa.openshiftapps.com` | Regional pipeline              | Zone shard; creates NS record in the regional zone (3). Grants permissions to external-dns and cert-manager from each MC. Informs seaplane-operator of all zone shards. |
| 6–8 | Cluster API, OAuth, ACME records                        | MC external-dns / cert-manager | Created in the zone shard (5)                                                                                                                                           |
| 9   | NS delegation for `in.{...}` in shard                   | HyperShift CPO                 | DNSEndpoint CR picked up by external-dns on MC; delegates to the public ingress zone (11)                                                                               |
| 10  | Private ingress zone + records                          | HyperShift CPO                 | VPC-associated (not NS-delegated); created and reconciled in the customer account                                                                                       |
| 11  | Public ingress zone + records                           | HyperShift CPO                 | NS-delegated from the shard (5) via (9); includes ACME CNAME delegation for cert-manager                                                                                |
| 12  | `{cluster_alias}.hypershift.local`                      | HyperShift CPO                 | Private zone, VPC-associated, in customer account                                                                                                                       |

**Seaplane-operator responsibilities:**

- Create and reconcile `DNSReservation` CRs to reserve DNS prefixes within zone shards. Each reservation lives in the account namespace (`account-<accountID>`) for isolation, and global uniqueness of the prefix within its shard is guaranteed by a corresponding `Index` resource in the shard's uniqueness namespace (`dns-shard-<id>-reservations`). Reservations are decoupled from cluster names — a `DNSReservation` can exist before a cluster claims it (e.g. for shared-VPC flows).
- Monitor capacity and manage zone shard allocation (zone placement decision)
- Propagate the selected zone shard to HyperShift Operator via the HostedCluster CR spec

**HyperShift CPO responsibilities (ingress DNS):**

- Create and reconcile public and private Route 53 hosted zones for ingress in the customer's AWS account (10, 11)
- Establish DNS delegation from the service provider's zone shard (5) to the customer's public ingress zone (11) via DNSEndpoint CRs (9) picked up by external-dns on the MC
- Set up ACME DNS01 challenge delegation via CNAME records in the public ingress zone (11), enabling cert-manager to provision ingress certificates through CNAME-follow without write access to the customer's zone
- The private ingress zone (10) is associated to the customer VPC directly — no NS delegation needed
- This is gated behind a managed ingress DNS toggle on the HostedCluster spec (`AWSIngressDNSManagement: Managed`)

**Cert-manager note:** Cert-manager on MCs is configured to "follow CNAME", so it follows the ACME CNAME record in the customer's public ingress zone (11) which points at `{cluster_alias}.{hash4}.{zone_shard}.{deployment_name}.rosa.openshiftapps.com` in the zone shard (5). Cert-manager on MCs has access to create records only in the regional account.

### Domain Name Identifiers

| Identifier        | Length          | Purpose                                                                                                                                                 | Provenance         | Example                                                                    |
| :---------------- | :-------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------ | :----------------- | :------------------------------------------------------------------------- |
| `deployment_name` | 1–25 characters | Subdomain for a regional deployment. Defaults to the AWS region name; suffixed when multiple deployments share a region or for per-run CI environments. | Service            | `us-east-1` (len 9), `us-east-1-2` (len 12), `us-east-1-eph-a1b2` (len 19) |
| `zone_shard`      | 1–3 characters  | Subdomain for a regional deployment's HostedZone shard (capped at 100)                                                                                  | Service            | `0` (len 1), `99` (len 2)                                                  |
| `hash4`           | 4 characters    | Unique slug per `cluster_alias` within a zone shard; allocated via `DNSReservation`/`Index` CRDs which guarantee uniqueness within the shard            | Service            | `1fb9` (len 4)                                                             |
| `cluster_alias`   | 1–15 characters | Alias for the cluster: user-provided (`domain_prefix`) or service-generated hash                                                                        | Service / Customer | `typeidhcp` (len 10), `4354c27df47cf4e` (len 15)                           |

All identifiers must be DNS-subdomain compatible: lowercase alphanumeric characters or `-`, starting and ending with an alphanumeric character.

### Cross-Account Access

external-dns and cert-manager run on MCs (in MC accounts) but need to create records in zone shards hosted in the regional account. The access pattern uses EKS Pod Identity with OU-based cross-account trust:

- **MC side**: Each operator pod (external-dns, cert-manager) gets an EKS Pod Identity role in the MC account. This role has `sts:AssumeRole` permission for the regional account's cross-account role.
- **RC side**: An IAM role in the regional account with Route 53 permissions (`route53:ChangeResourceRecordSets`, `route53:ListHostedZones`, `route53:GetChange`) scoped to zone shard HostedZones.
- **OU-based trust**: The RC-side role's trust policy uses an `aws:PrincipalOrgPaths` condition to trust any account in the MC organizational unit. The OU path is read from SSM Parameter Store (`/infra/<environment>/<region>/ou-path`, e.g. `/infra/stage/us-east-1/ou-path`) in the RC account. New MC accounts automatically get access when added to the OU — no RC-side IAM updates are needed when scaling MCs.

Route 53 IAM does not support scoping by record type, so external-dns and cert-manager share the same cross-account role. Operator configuration determines which record types each creates.

**Example FQDNs:**

```text
api.typeidhcp.1fb9.0.us-east-1.rosa.openshiftapps.com
openshift-console.apps.in.typeidhcp.1fb9.0.us-east-1.rosa.openshiftapps.com
```

**Maximum `.apps` domain length:** 34 static chars + 47 dynamic chars from identifiers = **81 characters**:
`.apps.in.{15}.{4}.{3}.{25}.rosa.openshiftapps.com`

## DNSSEC Configuration

### Cloudflare → Central Account

1. Top-level domain `rosa.devshift.net` must have DNSSEC enabled in Cloudflare
2. The DS record generated must be added to the domain registrar
3. Cloudflare delegates `int0.rosa.devshift.net` to the Central account
4. In Route 53, `int0.rosa.devshift.net` must have DNSSEC enabled (requires an `ECC_NIST_P256` Customer Managed Key)
5. The DS record generated in Route 53 must be added to `int0.rosa.devshift.net` in Cloudflare

### Central Account → Regional Account

1. Central account delegates `{deployment_name}.int0.rosa.devshift.net` to the Regional account
2. Enable DNSSEC for `{deployment_name}.int0.rosa.devshift.net` in the Regional account (requires a KMS key)
3. The DS record generated in the Regional account must be added to the Central account's delegation

### DNSSEC Validation (FedRAMP)

FedRAMP requires DNSSEC validation in every VPC where our processes reside:

- Route 53 → VPC Resolver → VPCs → Enable DNSSEC validation on the VPC

## Rollout Plan

### Phase 1 — Kube-API DNS and Certificates

Phase 1 covers DNS hierarchy levels 1–8 (all records in the service provider's account):

1. **DNS delegation setup** — establish the Cloudflare → environment zone → regional zone delegation chain for int, ci, and dev environments
2. **Zone shard creation** — create initial zone shard(s) per regional zone
3. **Cross-account IAM** — create the RC-side IAM role with OU-based trust and MC-side Pod Identity roles for external-dns and cert-manager
4. **Operator zone shard awareness** — seaplane-operator tracks zone shard capacity and propagates the selected shard to the HostedCluster CR
5. **Operator update** — update HostedCluster manifest rendering in the operator to include the DNS domain in the HostedCluster spec

### Phase 2 — Customer Ingress DNS (pending HyperShift RFE)

Phase 2 covers DNS hierarchy levels 9–12 (customer account zones) and depends on the HyperShift managed ingress DNS RFE:

- HyperShift CPO creates and reconciles public + private ingress zones in the customer account
- NS delegation from the zone shard to the customer's public ingress zone via DNSEndpoint CRs
- ACME CNAME delegation in the customer's public ingress zone for cert-manager to provision ingress certificates
- Gated behind `AWSIngressDNSManagement: Managed` on the HostedCluster spec

## Alternatives Considered

1. **Associated HostedZone(s) in our own accounts**: We would need private and public HostedZones in a Red Hat account. Public zones work, but private zones require linking the customer's VPC to the HostedZone. Additionally, the ingress operator would need credentials to create records in RH-owned zones. The lift is not worth the benefit — customers can still break the HostedZone association, so we don't fully own ingress certificate challenges.

2. **ACME wildcard at a higher hierarchy level**: Creating an ACME record in a higher-level zone for a wildcard certificate does not work because wildcard certificates are only valid at the same level.

3. **Bare `aws_region` as DNS identifier**: Using just the AWS region name (e.g., `us-east-1`) in DNS would be simpler but prevents multiple deployments of the same region within an environment. This is needed for CI (concurrent ephemeral deployments in the same region) and for production variants (e.g., `eu-west-1` vs `eu-west-1-fedramp`).

## Design Rationale

- **Justification**: The `deployment_name` approach preserves the simplicity of using the region name as the DNS subdomain in the common case while supporting multi-deployment scenarios. Zone sharding provides effectively unlimited record scaling (10k shards × 10k records = 100M records per region).
- **Evidence**: Route 53 quota of 10k records per HostedZone is a hard initial limit. The current single-zone architecture will hit this ceiling. Zone sharding is an established pattern used by GCP HCP DNS.
- **Comparison**: The `deployment_name` identifier is preferred over bare `aws_region` because it allows `us-east-1-2` or `us-east-1-fedramp` as deployment names that map to the same underlying AWS region. `deployment_name` is an explicit config field with a sensible default (`"{{ aws_region }}"`) — the common case requires no override, while CI and multi-deployment scenarios override it in environment or region config.

## Consequences

### Positive

- DNS scales to ~100M records per region via zone sharding
- DNSSEC chain of trust from Cloudflare to regional zones satisfies FedRAMP
- Certificates are fully managed within Red Hat accounts — no dependency on customer zone configuration
- Multiple deployments per region are supported without special-casing
- Zero migration cost for existing single-deployment-per-region configurations

### Negative

- Zone shard management adds operational complexity (seaplane-operator must track capacity and placement)
- DNSSEC key rotation requires coordination across account tiers
- Multi-deployment scenarios require explicit `deployment_name` and `aws_region` overrides in config

## Cross-Cutting Concerns

### Reliability

- **Scalability**: 10k shards × 10k records per shard = 100M records per region. The global account scales to 10k regions.
- **Resiliency**: DNS is distributed across per-region accounts; a single region's DNS failure does not affect other regions.

### Security

- DNSSEC enabled and validated end-to-end (Cloudflare → Central → Regional), satisfying FedRAMP
- Cert-manager on MCs can only create records in the regional account — no cross-account write access
- Service-provider zones are public (required for ACME challenges); HyperShift CPO creates both public and private ingress zones in the customer account

### Cost

- Each zone shard is a separate Route 53 HostedZone ($0.50/month per zone)
- At 100 shards per region × 50 regions = 5,000 zones = $2,500/month for DNS hosting
- Query costs are volume-dependent but negligible relative to compute

### Operability

- Zone shards are created by the regional pipeline — no manual DNS management
- Seaplane-operator automates shard allocation and capacity monitoring
- `deployment_name` defaults to `aws_region` — no separate configuration step needed for the common case

## Testing Strategy

DNS infrastructure must be available in CI and shared-dev environments so that e2e tests can exercise the full HostedCluster DNS flow (zone creation, NS delegation, ACME challenges, record resolution).

### Persistent vs Per-Run Infrastructure

The DNS zone hierarchy splits into two tiers:

- **Persistent (pre-provisioned, survives across e2e runs)**:
  - Environment zone in the central account (e.g., `ci00.rosa.devshift.net`)
  - Created and owned externally by the [rosa-seaplane-internal](https://github.com/openshift-online/rosa-seaplane-internal) control account (`aws_route53_zone.environment`); rosa-seaplane only looks it up by name to delegate into it
  - Pre-provisioned once per environment and reused across runs
- **Per-run (created and destroyed with each e2e run)**:
  - Regional zone in the regional account — the `deployment_name` is suffixed with the CI run's unique identifier (e.g., `us-east-1-eph-a1b2.ci00.rosa.devshift.net`), so each run gets its own isolated zone. Created and destroyed as part of the existing RC terraform lifecycle.
  - Cluster-specific records (api, oauth, ACME challenge) in the regional zone — created by external-dns and cert-manager on the MC
  - Ingress zones (public + private) in the customer account — created and reconciled by HyperShift CPO
  - NS delegation from the regional zone to the customer ingress zone — created via DNSEndpoint CRs

This reuses the existing RC terraform for regional zone management — no extraction into a separate config is needed. The CI identifier suffix naturally leverages the `deployment_name` mechanism.

### Skipping the API Gateway Custom Domain

The environment hosted zone is always created and owned externally by rosa-seaplane-internal; rosa-seaplane looks it up by name rather than creating it. One flag controls provisioning speed for e2e environments:

- `enable_api_custom_domain` (default `false`) — when false, skips the ACM certificate and API Gateway custom domain (~20 minutes). The API Gateway invoke URL is sufficient for testing. Production/staging set this to `true`.

### Per-Environment DNS Domains

Each account set (CI, shared-dev) uses its own `dns.domain` injected via config overrides.

Proposed domains (4-char prefix, matching `int0`/`stg0` length):

| Environment | Domain                   | Central Account |
| :---------- | :----------------------- | :-------------- |
| Integration | `int0.rosa.devshift.net` | (existing)      |
| CI          | `ci00.rosa.devshift.net` | CI central      |
| Shared-dev  | `dev0.rosa.devshift.net` | Dev central     |

### Scaling

The environment zone scales to 10k regional NS delegations. Adding regional or MC accounts just means more per-run regional zones under the same environment zone — no new Cloudflare delegations or domain changes needed.

### Prerequisites

Each new environment requires a one-time setup:

1. Cloudflare/app-interface delegation from `rosa.devshift.net` to the new environment subdomain
2. Creation of the environment hosted zone in the central account via rosa-seaplane-internal (`control-account` module)

DNSSEC is not required for CI/dev — only for FedRAMP compliance in staging and production.
