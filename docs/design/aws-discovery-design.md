# AWS discovery API design for Seaplane

**Last Updated Date**: 2026-11-18

## Summary

Separate live AWS-account discovery (`cloud_discovery`) from Seaplane-owned
metadata (`seaplane_discovery`). The static role-to-managed-policy ARN mapping
may be exposed through a Seaplane REST route, embedded in the Go SDK/clientset,
or both. Creating or retrieving the account association validates its role;
AWS discovery queries also validate account access. Do not add a separate
validation-only endpoint. The mapping contains ARN references only—no policy
documents or policy-version metadata—because AWS owns the managed policy.
Do not add a region-list endpoint: each Seaplane API server serves one
configured region.

The AWS-backed operations depend on a general cross-account role-assumption
contract that Seaplane does not currently expose. Resolve that prerequisite
before implementing the live AWS routes.

## Context

`uhc-clusters-service` exposes AWS inquiries used by clients and cluster setup
flows. They mix live AWS queries, OCM metadata, static catalogs, and a TLS
lookup. Treating them all as one feature to copy would bring OCM-specific
dependencies and unexpected effects into Seaplane.

The `rosa-seaplane-api` repository is a SigV4-authenticated REST gateway that
receives trusted caller account/ARN identity from API Gateway, performs Cedar
authorization, and reads/writes account-scoped resources. That identity does
not give the API process the caller's AWS SDK credentials. Current `Cluster`
resources service-set the owning `accountId`; visible AWS `rolesRef` is for
HyperShift IAM operator roles, not general API credentials.
`OidcConfig.spec.installerRoleArn` currently supplies the role used to read an
unmanaged OIDC signing-key secret. This design replaces that per-config field
with the account's sole access association; the migration is part of this work.
The regional API configuration already identifies its AWS region; a customer
who needs a different region connects to that region's Seaplane server.
The value is `Regional.AWSRegion` in the API configuration.

Relevant references:

- Clusters Service route registration:
  `uhc-clusters-service/repository/cmd/clusters-service/servecmd/apiserver/routes.go`
- Seaplane API route registration:
  `rosa-seaplane-api/seaplane-api/pkg/server/server.go`
- Current operator-role definition options:
  `rosa-seaplane-api/docs/api/manage-operator-roles-trust-policy.md`
- Existing asynchronous preflight proposal:
  `rosa-seaplane/docs/design/aws-preflight-design.md`

## Existing `aws_inquiries` endpoint catalog

The source router registers nine routes under
`/api/clusters_mgmt/v1/aws_inquiries`. Permissions below are inferred from the
current code paths; exact calls depend on request filters and feature-toggle
state. AWS permissions are distinct from OCM authentication, authorization,
and service-control-plane permissions.

| Existing route | Behavior | AWS permissions / access identified |
| --- | --- | --- |
| `POST /validate_credentials` | Builds a customer AWS client, validates credentials, and verifies that the credential account matches the supplied account ID. The handler currently writes the inquiry request back as its response. | `sts:GetCallerIdentity` identifies the account; AWS does not require an identity-policy allow for this call. If credentials are obtained by assuming an Installer/OCM role, the Clusters Service trusted principal needs `sts:AssumeRole` and the target role must trust it (with the configured ExternalId). |
| `POST /regions` | Intersects the service's enabled/allowed region catalog with regions opted into by the AWS account; can also filter by OpenShift version. | Customer role: `ec2:DescribeRegions`. Client creation/account verification also uses `sts:GetCallerIdentity`; role-based access additionally requires the service-side `sts:AssumeRole` flow. |
| `POST /machine_types` | Returns enabled AWS machine types intersected with offerings available in the selected region or requested AZs. | Customer role: `ec2:DescribeAvailabilityZones` and `ec2:DescribeInstanceTypeOfferings`. For compatibility, an unauthorized offerings call can fall back to `ec2:DescribeReservedInstancesOfferings`. The service may return its catalog without AWS filtering when offerings are unauthorized. |
| `POST /vpcs` | Finds VPCs, optionally by subnet or VPC IDs, and can include subnets and/or security groups. When subnets are included, it classifies them as public/private from their route tables. | Customer role: `ec2:DescribeVpcs`; `ec2:DescribeSubnets` when selecting by subnet or fetching subnets; `ec2:DescribeRouteTables` when computing subnet public status; `ec2:DescribeSecurityGroups` when fetching security groups. |
| `POST /sts_account_roles` | Assumes the organization's OCM-linked role, then lists ROSA-style account roles filtered by role naming and tags. | Assumed customer role: `iam:ListRoles` and `iam:ListRoleTags`; `iam:GetRole` may also be called when the OCM-role-validation feature toggle is enabled. Service trusted principal: `sts:AssumeRole` to the selected OCM role, with the OCM organization ID as ExternalId in this path. |
| `POST /sts_ocm_role` | Resolves the OCM-linked role for the requested AWS account and returns its ARN/type/profile metadata. | Assumed customer role: `iam:GetRole` (for role-tag/trust-policy validation when enabled and to retrieve the role details). Service trusted principal: `sts:AssumeRole` to the OCM role, plus OCM label/account-manager lookup. |
| `GET /sts_policies` | Lists policy templates from the service catalog and interpolates environment/org fields. This is not a pure read: the router explicitly warns that the request may create an AMS label and an AWS support role when support-role isolation is enabled. | Normally no customer-account IAM permission for reading the catalog. The service may call STS `GetCallerIdentity` (no IAM allow required). With support-role isolation, its own platform/provisioner identity may use `sts:AssumeRole`, `iam:GetRole`, `iam:CreateRole`, `iam:TagRole`, and `iam:UpdateAssumeRolePolicy`; it can also create/update an OCM organization label. These are service-side permissions, not customer discovery-role permissions. |
| `GET /sts_credential_requests` | Returns a static list of operator credential-request definitions, optionally filtered for HyperShift. | None; local catalog lookup only. |
| `POST /oidc_thumbprint` | Looks up an authorized Cluster or OIDC config, then retrieves the issuer's TLS certificate thumbprint. | None in AWS IAM. Requires account-scoped API/database access and outbound HTTPS/TLS reachability to the configured issuer. The input is an existing object ID, not an arbitrary URL. |

### Source-audit notes

- Endpoints accepting customer AWS configuration use the Clusters Service
  customer-client flow. It may use supplied access keys, an Installer Role ARN,
  or an OCM role label. Seaplane should not copy the long-lived access-key
  option.
- The legacy `validate_credentials` success path writes the inquiry request
  back as its response, so it may echo submitted credential fields. Seaplane
  should accept only an association identifier and must never preserve that
  echo behavior.
- `GetCallerIdentity` is account verification, not an IAM permission check.
  `sts:AssumeRole` is the separate permission/trust boundary when the service
  obtains a customer session.
- `sts_policies` is explicitly side-effecting in the route comment. Do not port
  it as a GET handler that can create IAM roles or organization labels.
- The source router contains `sts_ocm_role`, but the checked-in Clusters
  Service OpenAPI snapshot does not list that path. Use router/handler code as
  the route inventory and reconcile the generated documentation discrepancy
  before claiming API parity.

## Seaplane design

### Recommended scope

#### Account association and live AWS discovery

Use one account-scoped association per AWS account under
`/cloud_discovery/account_association`. Creating and retrieving the association
both validate its role, so no separate validation-only route is needed.

```text
POST /api/v0/cloud_discovery/account_association
GET  /api/v0/cloud_discovery/account_association
GET  /api/v0/cloud_discovery/machine_types
GET  /api/v0/cloud_discovery/vpcs
GET  /api/v0/cloud_discovery/operator_roles
```

If the REST delivery option is selected for Seaplane-owned metadata, also expose
`GET /api/v0/seaplane_discovery/role_policy_mapping`.

All account-scoped requests resolve the caller's sole association using trusted
gateway account identity. Do not require an association ID in these requests or
accept an account ID from the body/query. The AWS region comes from the
regional API deployment; do not accept a region override or expose region
enumeration. AZ, VPC, subnet, and inclusion filters are request inputs. Keep
responses bounded, deterministic, and free of credential material. A customer
wanting another region uses that region's Seaplane API server.

**POST creates and validates the account's association.** The request
identifies a role through the approved association-creation contract. The exact
role-reference source/field remains to be decided, but it is durable
association data, not a per-request role override. Do not accept static access
keys, secret keys, session tokens, or a caller-supplied ExternalId.

Before persisting an association, verify its target role account matches the
authenticated account, assume the role with the service-owned ExternalId, and
call STS `GetCallerIdentity` to verify the assumed account. If the association
is the Seaplane Installer Role, also apply the full trust-policy validation in
`aws-preflight-design.md`; a successful assume alone does not prove that no
broader trust statement exists. Persist only after successful validation and
return a validation summary, never credentials. Enforce uniqueness by AWS
account across regions, not one binding per API server or Cluster. A repeated
POST for the same binding should be idempotent; a different binding for an
account with an existing association must conflict unless an explicit
role-rotation flow is defined.

**GET retrieves and revalidates.** Resolve the sole association from the
authenticated account, repeat role assumption/account validation (and the
Installer Role trust check if applicable), and return the association with a
fresh validation result. If the association exists but its role has since been
deleted, lost trust, or resolves to the wrong account, return the association
with an actionable invalid result rather than treating it as missing. The
proposed GET performs AWS assume/read operations but does not mutate the stored
association; include a check time if useful, but do not imply that this result
persists as current status. Define stable responses for AWS transport or
authorization failures.

Machine-type and VPC requests also resolve the account's sole association and
independently authorize it, assume its stored role, and verify account binding.
They must not trust an earlier GET result as proof of current access or of the
specific EC2 permissions needed by that query. STS `GetCallerIdentity` does
not require an IAM `Allow`; a successful role validation also does not prove
the role has EC2 read permissions. Actual machine-type/VPC calls surface
missing `ec2:DescribeAvailabilityZones`,
`ec2:DescribeInstanceTypeOfferings`, `ec2:DescribeVpcs`,
`ec2:DescribeSubnets`, `ec2:DescribeRouteTables`, or
`ec2:DescribeSecurityGroups` permissions as applicable. The Seaplane role
mapping catalog is static and does not need an account association.

#### Customer-account operator role discovery

`GET /api/v0/cloud_discovery/operator_roles` lists recognized Seaplane
operator roles actually present in the authenticated customer's AWS account.
The handler assumes the account's sole association and filters IAM results to
the Seaplane role naming/tag contract; do not return an unrestricted account
role inventory. Candidate permissions are `iam:ListRoles` and
`iam:ListRoleTags`. Add `iam:GetRole` only if the response or validation must
inspect trust policies. This is live customer-account discovery and therefore
is association-scoped, unlike the static role mapping below.

Use V2 role naming/tags and the current shared role definitions; do not
mechanically copy OCM's account-role conventions. Define what the endpoint
returns when the account has no matching roles and how partial/missing role sets
are represented.

#### Seaplane role-to-managed-policy mapping

Expose the mapping as a pure read-only Seaplane-owned catalog. If REST delivery
is selected, use:

```text
GET /api/v0/seaplane_discovery/role_policy_mapping
```

It returns the canonical Seaplane role identifiers (such as role suffix/name
and service account) and the AWS-managed policy ARN(s) intended for each role.
For example, a mapping entry might include
`managedPolicyArns: ["arn:aws:iam::aws:policy/service-role/ROSA..."]`.
Customers can use those ARNs to link/attach AWS-managed policies when creating
the corresponding roles.

This static endpoint describes Seaplane's intended mapping; it does not inspect
a customer's IAM role or claim that a policy is attached. AWS owns the managed
policy document and its policy versions. Do not return policy JSON, add
policy-version metadata, or duplicate AWS policy contents in Seaplane. If a
future workflow must verify policies actually attached to a customer role,
treat it as a separate account-scoped AWS operation.

Source the mapping from one canonical role-definition source, ideally the
shared `iam/` definitions discussed in
`rosa-seaplane-api/docs/api/manage-operator-roles-trust-policy.md`. Do not
maintain a handler-local copy. Normal API deployment updates are sufficient;
no policy-catalog version field or dynamic policy overlay is needed for
ARN-only managed-policy references. Operator/service-account metadata from
`sts_credential_requests` can inform this static mapping without retaining an
OCM-specific endpoint.

The `seaplane_discovery` namespace can later expose Seaplane-owned
configuration and platform limits. Keep static product configuration/limits
separate from AWS account service quotas, which require live AWS access and
belong under `cloud_discovery`.

### Delivery and data-source options for `seaplane_discovery`

The role-policy mapping is static Seaplane metadata: it maps role definitions
to AWS-managed policy ARNs and contains neither customer data nor policy
documents. The delivery surface and the source of truth are separate decisions.
If multiple surfaces are provided, they should read the same canonical data
rather than maintain independent copies.

#### REST route versus SDK/clientset

| Delivery option | Pros | Cons |
| --- | --- | --- |
| REST route (`GET /api/v0/seaplane_discovery/role_policy_mapping`) | Works for Go and non-Go clients; exposes the catalog shipped with the API deployment; can be extended with other Seaplane-owned discovery, such as configuration and platform limits; has one documented HTTP contract. | Requires API availability, a hand-wired route/response contract, authz and rate-limit decisions; regional deployments can expose different data during rollout; clients needing offline behavior still need a local copy. |
| Embed in the Go SDK/clientset | No API round-trip; works offline and is deterministic for the pinned dependency; convenient for Go CLI/provider consumers. | Go-only; every mapping change requires a dependency update; non-Go consumers cannot use it; mapping may become stale in pinned clients. The current clientset is mostly generated CRD/resource clients, so static data must not be inserted into generated files. |
| Shared package plus both surfaces | One canonical mapping can feed REST and an optional Go accessor; supports offline Go use and non-Go HTTP clients without handler/SDK duplication. | Maintains two delivery surfaces; API data follows deployment rollout while embedded SDK data follows client dependency upgrades, so temporary skew remains possible. |

#### Data source and loading choices

| Data source | Pros | Cons / considerations |
| --- | --- | --- |
| Go constants or an embedded YAML/JSON file in a shared package | Reviewed with role-definition changes; available at startup with no runtime network or extra IAM dependency; can be validated by unit tests. | Changes require a code change/build; API regions see changes only as deployments roll out, and SDK consumers only after upgrading. |
| GitOps-managed YAML/JSON (for example, a ConfigMap) | Changes are reviewed in Git and can be rolled out as deployment configuration; can support regional or environment-specific catalogs if those become required. | Requires schema validation and a defined mount/watch/reload or rollout mechanism; region-specific edits can drift; adds Kubernetes/GitOps coupling for data that may be static. |
| S3-hosted YAML/JSON, possibly published by GitOps | Supports centralized publication and updates without rebuilding the API; ETag/cache controls can reduce repeated reads; non-Go clients can consume the same artifact. | Requires S3 permissions, integrity/change control, schema validation, cache/stale-data/fallback behavior, and a runtime availability decision; regional APIs and pinned SDKs can observe different revisions. |

The current mapping contains only AWS-managed policy ARN references, so policy
documents and AWS policy-version fields are not part of the catalog contract.
The mapping can still change when Seaplane role definitions or ARN associations
change; required update cadence, non-Go consumption, offline behavior, and
regional consistency determine which delivery and loading option fits.

### Customer AWS access contract

Maintain exactly one durable AWS access association per AWS account across
Seaplane regions. POST creates it; GET and AWS discovery resolve it using the
authenticated account, without an association ID or customer-supplied account
ID. The role reference and service-owned ExternalId are stored/resolved by
Seaplane. Discovery requests do not accept request-local role ARNs, static AWS
credentials, or caller-supplied ExternalIds.

The current Seaplane API has no general AWS access association. Add or
integrate an account-scoped store/resource with global account uniqueness.
Connect it to the Installer Role/trust proposal in
`aws-preflight-design.md` so discovery and preflight do not use independent
role sources. A repeated POST for the same association should be idempotent;
a different role for an account that already has an association must conflict
until an explicit role-rotation flow is designed.

`OidcConfig.spec.installerRoleArn` is currently used by the operator to read an
unmanaged OIDC signing-key secret. Plan to remove this field from the OIDC
Config spec and use the account's sole association for that cross-account read.
The OIDC operator must resolve the association using the OIDC config's
service-set account ID, assume the associated role, then read the configured
secret. Before removing the field from validation, public REST types,
CRD/OpenAPI, and generated clients, verify whether any existing resources need
to be preserved. Since Seaplane is still in development, migration may not be
needed: if current associations/OIDC configs can be discarded, remove the
field and recreate the association and configs under the new contract. If data
must be retained, migrate each account's association and verify its unmanaged
OIDC configs can still read their secrets. The association role must permit
`secretsmanager:GetSecretValue`; customer-managed KMS encryption may
additionally require `kms:Decrypt` and a compatible key policy.
`Cluster.spec.hostedCluster.platform.aws.rolesRef` remains a separate
HyperShift operator-role reference.

The API runtime role needs narrowly scoped `sts:AssumeRole` to roles referenced
by authorized associations, and the customer trust policy must name the
API runtime role as the approved principal and require the exact service-owned
ExternalId. Preflight and OIDC-secret-read consumers use this same trust
option; do not add a second customer-trusted principal. Update the current
`aws-preflight-design.md` trust check to validate the API runtime principal
under this shared contract. The associated role should grant only the retained
discovery, preflight, and OIDC-secret-read actions.

### Endpoint dispositions

| Source capability | Seaplane disposition |
| --- | --- |
| Credentials validation | Replace the standalone validation route with POST create-and-validate and GET account-scoped retrieve-and-revalidate. Machine-type/VPC queries also validate the account's association. |
| Regions | Omit the region-list endpoint. The API server serves a single configured region; customers select another region by connecting to its server. |
| Machine types, VPCs | Adapt as the bounded, AWS-backed discovery operations above, using the API server's configured region. Keep calls behind an injectable service/client interface, not in HTTP handlers. |
| STS account-role enumeration | Adapt as `cloud_discovery/operator_roles`: return recognized operator roles found in the caller's AWS account using the sole association. Filter by V2 role names/tags rather than OCM organization labels. |
| OCM role details | Omit. OCM account-manager labels and role profiles have no direct Seaplane equivalent. |
| STS policy catalog | Do not port the legacy side-effecting GET. Expose the role-to-AWS-managed-policy ARN mapping through the pure `seaplane_discovery/role_policy_mapping` catalog. |
| STS credential requests | Fold relevant role/service-account metadata into `seaplane_discovery/role_policy_mapping` if canonical definitions own it. |
| OIDC thumbprint | Do not add a parallel endpoint. Seaplane already computes and refreshes `OidcConfig.status.thumbprint`; callers can read the existing account-scoped OIDC config. Remove `OidcConfig.spec.installerRoleArn` and have the operator resolve the account's sole association when reading an unmanaged OIDC secret. |

This remains distinct from AWS preflight. Discovery returns data for a client to
select and submit; preflight validates a proposed Cluster/NodePool and reports
asynchronous status. Avoid duplicating preflight checks in discovery handlers
or blocking cluster creation on list operations.

## Alternatives considered

1. **Synchronous Platform API discovery (recommended for live AWS lists).**
   Preserves interactive CLI/console flows and centralizes account binding,
   error mapping, and least-privilege AWS calls. It depends on a safe role
   contract and adds AWS latency/availability to the request.
2. **Operator-backed asynchronous discovery request.** Reuses operator AWS
   identity patterns, but adds a request/status resource, polling, lifecycle
   cleanup, and latency unsuitable for simple machine-type/VPC selection. Use for
   long-running checks, not simple list queries.
3. **Client-side AWS queries/shared client library.** Avoids Seaplane service
   trust and API runtime AWS permissions, and works offline; however, each
   client must implement filtering and error handling. This is a viable fallback
   if Seaplane cannot safely assume a customer role.
4. **Operator-role catalog only.** A static ARN mapping is useful but cannot
   answer account opt-in, VPC, subnet, or security-group questions.

## API integration and security constraints

The API repository's routes are hand-wired, while resource schemas and generated
public OpenAPI/client artifacts are derived from CRDs:

- Register handlers in `seaplane-api/pkg/server/server.go`, following existing
  route construction and account identity middleware.
- Add `POST` and account-scoped `GET` handlers for
  `/api/v0/cloud_discovery/account_association`; POST validates and creates the
  sole association for the authenticated AWS account, while GET resolves that
  association from identity and revalidates it without an ID parameter.
- Enforce one association per AWS account globally across regional API servers.
  Use a store/uniqueness mechanism shared or coordinated across regions; a
  per-region-only uniqueness check is insufficient.
- Put AWS calls behind a discovery service interface/package; keep parsing,
  authz, and response conversion in `pkg/handlers`.
- Add explicit Cedar actions and schema entries. Keep account-specific AWS
  reads, association management, and the static Seaplane catalog as distinct
  authorization operations. Do not implicitly grant AWS inventory access
  through every existing `ReadOnly` grant without a product decision.
- Apply registered-account/allowlist behavior and rate limits; bound
  concurrency per account and AWS API.
- Add explicit Cedar actions for association creation/retrieval and discovery
  reads. Resolve the sole association from trusted account identity, verify its
  stored role account/partition, then call `AssumeRole`; fail closed on lookup
  or assumption errors. Never accept request-supplied AWS credentials or
  ExternalIds.
- Limit `cloud_discovery/operator_roles` to recognized Seaplane V2 role
  naming/tag patterns and the IAM calls it needs. Keep the static
  `seaplane_discovery/role_policy_mapping` catalog account-independent.
- Remove `installerRoleArn` from the OIDC Config API/CRD contract after
  migrating existing unmanaged OIDC configs to their account associations.
  Update the OIDC controller to resolve the account association for
  `ReadCrossAccountSecret`; verify operator access to the association store and
  the customer role's `secretsmanager:GetSecretValue` (and conditional
  `kms:Decrypt`) permissions.
- Use only the read actions listed above. No permission probes that create or
  delete customer resources.
- `cloud_discovery/operator_roles` needs customer-role `iam:ListRoles` and
  `iam:ListRoleTags` (and `iam:GetRole` only if role trust is inspected).
  `seaplane_discovery/role_policy_mapping` performs no AWS calls and its
  `managedPolicyArns` are references to AWS-owned policies.
- The CRD-derived `api/v1alpha1/public/openapi.yaml` and generated Kubernetes
  clientset do not automatically describe a hand-written REST endpoint. Add a
  REST contract and client surface deliberately if consumers need one.

## Consequences

### Positive

- Gives customers interactive AWS inventory without putting long-lived AWS
  credentials in Seaplane API requests.
- Makes the operator role-to-managed-policy relationship discoverable without
  duplicating AWS policy documents or versions.
- Keeps OCM account-manager roles and support-role side effects out of Seaplane.
- Separates static role mapping, live customer IAM/AWS discovery, and
  asynchronous preflight.
- Makes one account association reusable by discovery, preflight, and OIDC
  secret retrieval instead of duplicating role references.
- Makes the customer role's minimum AWS read permissions auditable and testable.

### Negative and risks

- A cross-account role relationship, ExternalId, and runtime `sts:AssumeRole`
  policy are not currently a general Seaplane API contract.
- Customer IAM policy drift or AWS outages can make live discovery unavailable.
- Synchronous AWS calls add latency, request volume, and throttling concerns.
- Existing REST SDK support is not generated from the CRD OpenAPI pipeline.
- The role-to-policy mapping must have one canonical owner so whichever delivery
  surfaces are selected do not drift from CLI/TF role creation.
- Global one-association-per-account enforcement and migration away from
  `OidcConfig.spec.installerRoleArn` require coordinated storage and rollout
  across API and operator components.

## Open decisions

1. Which API/service/store owns the association and enforces global
   AWS-account uniqueness? What approved role reference does POST accept?
2. Should GET return invalid-role validation results in-band with the
   association or as stable API errors? Validation is not persisted by the
   current proposal.
3. Can live discovery use a separate read-only role, or must it reuse the
   provisioning Installer Role?
4. Which clients require REST methods, and which may use direct AWS/library
   calls?
5. Which role identifier, service-account fields, and managed-policy ARN(s)
   belong in the operator-role catalog? Does role applicability require any
   filters beyond the current V2 definitions?
6. Should the static operator-role endpoint be included in Cedar `ReadOnly` or
   have its own action?
7. Which AWS partitions are supported? The target region itself is fixed by
   the regional API server.
8. Are account-specific machine-type results cached, and what freshness
   contract is acceptable?
9. What are duplicate POST behavior, explicit role rotation, deletion, and
   protection while the association is referenced?
10. Can existing unmanaged OIDC configs/associations be discarded while the
    service is in development, or must their `installerRoleArn` data be
    migrated?
11. Should role-policy mapping use REST, SDK/clientset embedding, or both, based
    on consumer language mix and offline/update needs?
12. Should the mapping be shared source code/data, GitOps-managed configuration,
    S3-backed data, or another source? What reload, cache, fallback, and
    cross-region consistency semantics are required?

## References

- Implementation plan: `../../../plans/aws-discovery-implementation.md`
- `rosa-seaplane-api/docs/api/manage-operator-roles-trust-policy.md`
- `rosa-seaplane-api/docs/api/feature-gating-design.md` §3.10 (example of a
  customer-facing discovery route)
- `rosa-seaplane-api/docs/authz/README.md`
- `rosa-seaplane/docs/design/aws-preflight-design.md`
