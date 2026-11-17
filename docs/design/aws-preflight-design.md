# AWS preflight design for Seaplane

Code paths under `api/v1alpha1`, `seaplane-api`, and `seaplane-operator` refer
to the `rosa-seaplane-api` repository unless otherwise noted. Paths prefixed
with `clusters-service:` refer to the `uhc-clusters-service` repository.

## Goal

Move AWS account and resource preflight checks out of the synchronous
`uhc-clusters-service` request path and into the Seaplane operator. Report the
latest result on the corresponding Cluster and NodePool status and rerun checks
periodically. Checks report asynchronously by default; explicitly configured
per-step gates may hold the target's initial ApplyDesire admission.

Controller-owned observations belong under `.status`, not `.spec`. The existing
Cluster and NodePool APIs already expose status conditions through their public
representations; preserve that pattern rather than adding customer-writable
preflight fields.

## Existing behavior

### `uhc-clusters-service`

- `ClusterService.Create` runs AWS preflight synchronously for clusters selected
  by `requiresPreflightChecks` (currently unmanaged or CCS clusters). A failed
  check rejects cluster creation. The call occurs before the dry-run return, so
  dry-run also performs the checks.
- The AWS implementation is
  `clusters-service: cmd/clusters-service/service/aws_preflight/preflight_service.go`.
  It builds a customer-account AWS client, sets a 60-second overall timeout,
  and runs a group of checks concurrently. Some checks use a database
  transaction that is explicitly rolled back.
- The AWS check set covers account/role and permission checks; availability
  zones and instance offerings; VPC, CIDR, subnet, security group, DNS and tag
  validation; AMI access; and service quotas including vCPU, VPC, EIP, NAT,
  internet gateway, load balancer, S3, instance profile and security groups.
  Classic-ROSA-only checks, feature toggles and environment-specific services
  are mixed into that set and need an applicability review before porting.
- `PerformPreflightChecksOnPatch` is narrower than create-time preflight: it
  validates AWS credentials if a patch supplies both access and secret keys.
  It does not rerun the full set.
- Preflight accepts a legacy cluster model, feature-toggle service, database
  access, AWS helpers, and OCM-specific auth/transaction context. It is not a
  standalone package that can be copied directly.
- The legacy model places compute configuration inside a Cluster. Seaplane has
  separate Cluster and NodePool resources, so worker instance, subnet, AMI,
  profile, and tag checks need to be assigned to NodePool status where they
  depend on a particular pool.

## Existing AWS preflight catalog

The table describes callbacks registered by
`PreflightService.PerformPreflightChecks` in
`clusters-service: cmd/clusters-service/service/aws_preflight/preflight_service.go`.
The callbacks run concurrently, so this is a catalog rather than an execution
sequence; the legacy errgroup returns the first error it observes. Some checks
are conditional on cluster type, topology, or feature toggles. “Read” includes
AWS `Describe`/`List`/`Get` and `AssumeRole` calls that do not mutate customer
resources. “Write probe” attempts a write operation (possibly with `DryRun`) or
creates temporary resources that should be cleaned up. “Mixed” combines reads
with a write probe; “Local/control-plane” does not operate on customer AWS
resources.

| Existing step                                  | Operation type                     | What it checks / why it is used                                                                                                                                                                                                                               |
| ---------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `validateSharedVpc`                            | Read / assume-role                 | For shared-VPC clusters, checks cross-account role assumption and hosted-zone configuration, including zone names, records, and VPC association.                                                                                                              |
| `validateCCSRelated`                           | Read / control-plane               | CCS-specific bundle: checks account identity where applicable, AZs, BYO subnets, creator ARN and KMS key access, then install vCPU quota.                                                                                                                     |
| `validateAvailabilityZonePermissions`          | Read                               | Confirms the AWS identity can list AZs and query instance-type support, surfacing missing permissions early.                                                                                                                                                  |
| `validateCreateSecurityGroupPermissions`       | Write probe (`DryRun`)             | For ROSA, calls `CreateSecurityGroup` with dry-run enabled to check permission without creating a group.                                                                                                                                                      |
| `validateVpc`                                  | Read                               | For BYO VPC, checks that selected subnets share one VPC, supplied security groups are valid and within per-interface limits, the VPC is not ROSA-managed, and DNS support/hostnames are enabled.                                                              |
| `validateAmiAccess`                            | Mixed / write probe                | Classic ROSA only: resolves the expected release AMI, then simulates instance creation and cleans up the instance and any temporary VPC/subnet/security group; skips HyperShift.                                                                              |
| `validateS3BucketAvailableQuota`               | Write probe                        | Classic-only capacity check that creates and asynchronously deletes a temporary S3 bucket; skips HyperShift because its installer policy lacks the required S3 permission.                                                                                    |
| `validateVpcAvailableQuota`                    | Read                               | For applicable CCS clusters creating their own VPC, checks quota capacity for one more VPC; skips ROSA and BYO VPC.                                                                                                                                           |
| `validateCidr`                                 | Read                               | Checks applicable CIDR relationships: OVN overlap when enabled, machine CIDR containing the selected subnets, and service CIDR not overlapping them.                                                                                                          |
| `validateSecurityGroup`                        | Read                               | When security-group filters are configured, confirms a matching group exists in the VPC identified by the selected subnets.                                                                                                                                   |
| `validateVpcDefaultSecurityGroupRulesQuota`    | Read                               | Feature-gated HyperShift check that the VPC default security group has room for required rules.                                                                                                                                                               |
| `validateEIPQuota`                             | Read                               | For CCS clusters creating their own networking, checks Elastic IP quota for the requested AZ topology; BYO VPC and PrivateLink need none.                                                                                                                     |
| `validateInstanceProfileQuota`                 | Read or write probe                | For CCS, checks instance-profile capacity. Classic uses quota/usage APIs; HyperShift may create and delete a temporary IAM instance profile to probe capacity.                                                                                                |
| `validateLoadBalancerQuota`                    | Read                               | Checks available Classic Load Balancer and Network Load Balancer capacity using requirements for the cluster topology.                                                                                                                                        |
| `validateNATGatewayLimitExceeded`              | Read                               | For installer-created networking, checks NAT Gateway quota/usage per selected AZ; skips BYO VPC and PrivateLink.                                                                                                                                              |
| `validateInternetGatewayQuota`                 | Read                               | For installer-created VPCs, checks capacity for an Internet Gateway; skips BYO VPC.                                                                                                                                                                           |
| `validateServiceRoleForELBExist`               | Read                               | For STS clusters, confirms the AWS Elastic Load Balancing service-linked role exists.                                                                                                                                                                         |
| `validateHostedZoneLimit`                      | Read                               | Feature-gated HyperShift quota check that the account can create the hosted zones needed by the cluster.                                                                                                                                                      |
| `validateHcpLocalHostedZone`                   | Read                               | Feature-gated ROSA HCP check that the expected customer-account local private hosted zone does not already exist; skips shared VPC.                                                                                                                           |
| `validateClassicManagedPoliciesClusterVersion` | Local/control-plane                | For Classic STS clusters using managed policies, checks that the requested OpenShift version supports them.                                                                                                                                                   |
| `validateUnmanagedOidcConfig`                  | Read / external network            | For STS clusters using unmanaged OIDC, reads/validates the customer secret-backed signing key and checks issuer reachability. Seaplane should move cross-account key validation to asynchronous provisioning rather than duplicate a registration-time check. |
| `validateUserAccountForSts`                    | Read / assume-role / control-plane | Legacy OCM-specific check that the user's AWS role is linked/authorized for the cluster account through OCM role and account-manager services; no direct Seaplane equivalent is assumed.                                                                      |
| `validateSharedSubnets`                        | Read                               | For BYO VPC outside the shared-VPC flow, rejects subnets owned by an account other than the cluster account.                                                                                                                                                  |
| `validateSupportRoleForSts`                    | Read / control-plane               | Feature-gated STS check that the support role exists and trusts the required Red Hat support principal for the organization's support-isolation configuration.                                                                                                |
| `validateRoles`                                | Read                               | Checks role path restrictions and policy compatibility across account, support, worker, and applicable operator roles, including topology, version, and naming rules.                                                                                         |
| `validateSecurityGroupsQuota`                  | Read                               | Feature-gated account/region quota check that there is capacity for the security groups required by cluster installation.                                                                                                                                     |
| `validateSubnetTags`                           | Read                               | Checks required subnet tags for install-time auto-selection and, for applicable HyperShift flows, required public/private ingress subnet tags.                                                                                                                |
| `validateSubnetOwnership`                      | Read                               | Feature-gated BYO subnet ownership validation against ROSA's supported ownership rules.                                                                                                                                                                       |
| `validateAWSTags`                              | Local/control-plane                | Validates customer AWS tag keys and values against the AWS tag constraints used by the service; no AWS API call.                                                                                                                                              |
| `validateSecurityGroupQuota`                   | Read                               | Checks that configured additional compute, infra, and control-plane security groups fit the EC2 per-network-interface limit.                                                                                                                                  |

Two related checks are part of the migration inventory but are not callbacks in
that registry:

| Related check                                                                                       | Operation type      | What it checks / why it is used                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Network verifier worker (`clusters-service: cmd/clusters-service/service/network_verify_worker.go`) | Mixed / write probe | Separate asynchronous subnet egress-verification pipeline. It assumes the Installer Role, runs AWS network-verifier tooling (including temporary EC2 activity) for a subnet, and persists pass/fail details. Decide how its result maps into Seaplane Cluster or NodePool conditions.                                                         |
| Seaplane Installer Role trust-policy gate                                                           | Read / Block        | After assuming the Installer Role, use IAM `GetRole` to inspect the full trust policy. Require only the approved Seaplane service principal to be allowed to assume the role and require the exact service-owned `sts:ExternalId`; reject wildcard or alternate-principal/unconditional allows. This is a mandatory Cluster ApplyDesire gate. |
| Preflight artifact cleanup                                                                          | Read + delete       | New recovery operation: discover stale, Seaplane-tagged temporary resources left by interrupted preflight or network-verifier runs, then delete only resources that meet strict ownership and age criteria.                                                                                                                                   |

### Why the network verifier is separate

`PerformPreflightChecks` is a cluster-scoped batch invoked from the legacy
cluster-create request path. It runs registered validation callbacks against
the submitted Cluster model and returns an error to that request. In contrast,
`NetworkVerifyWorker` is a long-running, leadership-gated worker: it polls a
persisted network-verification queue (every 30 seconds), claims individual
subnet jobs by moving them from pending to running, and writes pass/fail state
and diagnostic details back to that job. Its run has a longer timeout (up to
10 minutes), recovers stale running jobs, and can optionally associate its
result with a separate inflight check.

The network verifier also has different inputs and effects. It runs the
`osd-network-verifier` egress test for a particular subnet, using credentials
from the Installer Role or its associated Cluster, and may use Cluster proxy,
custom CA, KMS, and instance-type settings. The AWS probe and temporary
resources make it a write-probe workflow, not just another `Describe` check.

Keeping it distinct in the catalog means **do not imply it currently runs in
the create-time preflight batch, shares that batch's Cluster-level inputs, or
has the same completion/error lifecycle**. It remains in the migration scope,
but its Seaplane design must separately define what enqueues a subnet test,
how retries/results are persisted, whether the result belongs to a Cluster or
NodePool condition, and how probe cleanup and cost are controlled. Its
`Observe`/`Block` policy must be decided explicitly; do not inherit the legacy
toggle. It should report asynchronously.

This catalog is an inventory, not a porting mandate. Map each retained check to
Seaplane Cluster/NodePool inputs and record its applicability, disposition
(retain, defer, move to provisioning, or omit), and condition reason.

### Seaplane

- The API handlers validate request shape and local constraints, then persist
  Cluster and NodePool CRs; they do not run customer-account AWS preflight.
- `ClusterReconciler` waits for placement and then writes HyperShift
  ApplyDesires. `NodePoolReconciler` resolves its parent Cluster and placement
  before writing its ApplyDesire.
- Both controllers periodically requeue as a status-refresh fallback, but that
  requeue is for DynamoDB/HyperShift status and is not an AWS preflight loop.
- Cluster and NodePool statuses already have list-map `metav1.Condition`
  collections, and the public status mirrors are generated. Status writes use
  `meta.SetStatusCondition` and conflict retries.
- The operator has AWS SDK configuration for its own regional services. Its
  OIDC infrastructure client can assume a customer role to read an external
  OIDC signing-key secret, but that is a narrowly scoped secret-read flow, not
  evidence that it can perform the broad AWS inspections required by preflight.

## Porting strategy options

The existing implementation is not a self-contained validator package: it
uses the legacy Cluster model, OCM auth/feature-toggle/account services,
transactions, DAOs, and AWS wrappers. Seaplane has different lifecycle and
status semantics, and splits some legacy Cluster inputs across Cluster and
NodePool. The choice is therefore about which layer to share, not just whether
to copy a directory.

| Option                                                | Approach                                                                                                                                                                                                                                                                  | Benefits                                                                                                                                                         | Costs / risks                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Extract a shared preflight module                  | Refactor reusable checks out of `uhc-clusters-service` into a versioned Go module used by both services.                                                                                                                                                                  | One implementation of shared checks; fixes and new common checks can reach both consumers; reduces behavioral drift.                                             | Largest upfront effort. Requires neutral input types and AWS interfaces, removing OCM models/services from the shared layer, module ownership/versioning and coordinated releases. A direct dependency on the current package would pull in legacy coupling and make Seaplane adapt to OCM-specific assumptions. |
| 2. Port only Seaplane-applicable checks               | Implement the selected checks inside `seaplane-operator`, adapting them to Installer Role access, Cluster/NodePool resources, Conditions, and periodic reconciliation.                                                                                                    | Smallest path to Seaplane behavior; can omit Classic/OCM-only checks and design around Seaplane’s async lifecycle; simplest dependency boundary.                 | Some logic will be duplicated. Upstream behavior changes may not reach Seaplane, so maintainers must track the catalog and consciously adopt fixes.                                                                                                                                                              |
| 3. Staged hybrid                                      | First port the curated Seaplane set behind a Seaplane-owned runner and neutral check inputs. Keep a parity/applicability catalog and shared contract tests. Extract only stable, genuinely common leaf checks into a shared module later, with both services adopting it. | Delivers Seaplane-specific behavior without blocking on a broad refactor, while creating a controlled path to share high-value logic and reduce drift over time. | Temporarily retains duplication; requires discipline to keep the catalog/tests current and to avoid premature abstractions in the operator package.                                                                                                                                                              |
| 4. Shared conformance suite, separate implementations | Keep each implementation local, but share a catalog and table-driven test vectors for checks that are intended to have equivalent outcomes.                                                                                                                               | Lower-cost way to detect drift; lets each system keep its own credentials, inputs, errors, and lifecycle.                                                        | Does not share fixes or implementation; fixture coverage must be maintained and cannot prove identical behavior for every AWS account state.                                                                                                                                                                     |

Calling the existing `clusters-service` preflight over an internal API is
another possible reuse mechanism, but is a poor fit: the operator would depend
on that service's availability, request model, and synchronous error contract,
and the customer-account check would no longer be owned by the operator
reconciler.

## Proposed behavior

### Reconciliation ownership

Use a dedicated AWS preflight reconciler in
`seaplane-operator/internal/controller` that reconciles internal
`PreflightResource` objects, with reusable checks in
`seaplane-operator/internal/preflight`. Cluster and NodePool reconciliation
ensures the corresponding PreflightResource exists and updates its target
generation when relevant inputs change. Keep AWS checks out of the API request
path and the normal HyperShift/DynamoDB status projection.

### Internal `PreflightResource`

Create or ensure one internal `PreflightResource` alongside each Cluster and
NodePool during its initial operator reconciliation. Set a controller
ownerReference to the target and validate the target kind, namespace, name, and
UID so a deleted target or reused name cannot inherit stale preflight state.
The operator owns this resource; it is not customer-writable or rendered to a
management cluster. Each resource contains a collection of applicable checks;
do not create a separate PreflightResource for every check. The `target`,
`check`, and `configuration` object shown below is the normalized fingerprint
input for one check within that collection.

The resource's spec stores a typed target reference, the generation/input
fingerprint to check, and an operator-owned policy for each step: `Observe`
(default) or `Block`, whether to run on input changes, and an optional periodic
interval. Customers do not set this policy through Cluster or NodePool spec.
Every `Block` step must run whenever its fingerprint changes; its scheduling
policy cannot suppress that required run. Periodic intervals control additional
drift checks, not whether a new blocking input revision is checked.
Its status stores per-step execution
metadata (for example, state, attempt, timestamps, reason, and sanitized
message) for that target revision. The preflight controller updates the step
results, derives an aggregate `Preflight` condition plus per-step conditions,
and syncs them to the target's status. The conditions report the latest results;
gate decisions use the internal per-step result and revision, not the aggregate
condition alone. Initially, per-step state is for execution visibility and
diagnostics, not a resume cursor: after restart, all applicable checks run
again.

#### Example step fingerprint input

Each preflight step uses a typed input with three root fields: `target`,
`check`, and `configuration`. For example, the `validateCidr` step for a
Cluster could hash:

```json
{
  "target": {
    "kind": "Cluster",
    "namespace": "account-123456789012",
    "name": "rosa-green",
    "uid": "cluster-uid-123",
    "generation": 12
  },
  "check": {
    "id": "validateCidr",
    "version": 1,
    "gateMode": "Observe"
  },
  "configuration": {
    "awsAccountId": "123456789012",
    "installerRoleArn": "arn:aws:iam::123456789012:role/Installer",
    "region": "us-east-1",
    "networkType": "OVNKubernetes",
    "podCIDR": "10.132.0.0/14",
    "machineCIDR": "10.0.0.0/16",
    "serviceCIDR": "172.30.0.0/16",
    "subnetIds": ["subnet-aaa", "subnet-bbb"],
    "ovnOverlapCheckEnabled": true
  }
}
```

Compute the step fingerprint as SHA-256 over a canonical encoding of those
fields, and store it with that step's result in `PreflightResource.status`.
Sort order-insensitive lists such as subnet IDs. Do not include status,
timestamps, `resourceVersion`, AWS credentials, session tokens, or secret
material. For a NodePool target, include a `parentCluster` identity/generation
under `target`; its step configuration includes the parent fields the check
uses, such as account, region, and role association. If account access is stored
in a separate resource, include its UID/generation and installer-role
association revision too. Including target, parent, and access-resource
generations is the conservative first version: any generation change invalidates
the step, even if that particular step's inputs did not change.

When a check finishes, re-read the target and its dependencies and recompute
the fingerprint before recording success or syncing conditions. Discard the
result and requeue if any input changed while the check was running. On every
blocking decision, use an uncached/APIReader read of the target, parent
Cluster, account-access resource, and PreflightResource result; compute the
current fingerprint and compare it with the step result. Do not trust informer
cache state alone for a gate decision. If the parent/access revision changes,
mark the affected NodePool conditions pending/stale and re-enqueue it. Do not
gate a NodePool using only its condition's `observedGeneration`: that field
reflects NodePool generation and does not change when its parent Cluster changes.

When the target is deleted, the operator must remove its `PreflightResource` as
part of target deletion. Use the target UID/owner relationship, but do not rely
on database garbage collection alone. The PreflightResource reconciler should
detect a missing or deleting target, clean up or hand off tracked AWS probe
artifacts, then remove the resource/finalizer and its run metadata.

The preflight controller should:

1. Run when a new PreflightResource is created or a step's fingerprint changes.
   Always run changed `Block` steps; `Observe` steps follow their configured
   input-change policy.
2. Resolve the latest target by kind/name/UID and its parent Cluster/account
   access resource if needed; discard results if any target or dependency input
   changed during the run.
3. Store per-step results in PreflightResource status and sync per-step plus
   aggregate conditions to the target using conflict-safe status updates.
4. On target or dependency input changes, run all applicable `Block` checks;
   run `Observe` checks only when their input-change trigger is enabled. On
   timer requeues, run only checks whose configured periodic interval is due;
   return `RequeueAfter` for the earliest next due check. Transient failures may
   use a shorter per-check retry interval.
5. Filter status-only PreflightResource updates so writing step status or
   syncing a target condition does not start an immediate repeated check.
   Target generation/input changes must update and enqueue the corresponding
   PreflightResource promptly. Parent Cluster and account-access watches must
   also invalidate/re-enqueue dependent resources; the gate still verifies the
   live revision in case those events have not been processed yet.
6. Use bounded concurrency, an overall timeout, and a shorter retry interval
   for transient AWS/API errors. Configure controller worker limits and a
   shared preflight admission limiter; add jitter to periodic requeues so AWS
   checks do not synchronize across resources.

Use per-check cadence separately from the existing five-minute status refresh.
Read-only conformance checks may run periodically to detect AWS drift. Write
probes (for example, temporary IAM profiles or network-verifier EC2 activity)
run when their inputs change; periodic execution should be disabled by default
or explicitly configured at a slower cadence after considering cost and quota
impact. Check failures update status and retry according to per-check policy,
not in a tight reconcile/error loop.

### Restart and startup staggering

`RequeueAfter` is scheduled in the controller's in-memory delayed workqueue; it
is not durable, and a restart does not resume an unconsumed timer or continue at
a particular check. When the manager starts, the informer lists existing
PreflightResources and delivers add events, which enqueue them again. The
preflight reconciler should treat these startup enqueues as fresh runs and
execute the full applicable check set from the beginning, even if the last
aggregate condition was successful. Per-step status may be reset/replaced as
the new run proceeds; it must not be used to skip checks after restart. The
legacy checks run concurrently, so this means a fresh check run, not a
sequential “step 1” restart. Ensure any event predicate admits initial add
events.

Startup add events can enqueue many resources at once. `MaxConcurrentReconciles`
bounds active reconciles, but does not evenly pace them. Use a shared
preflight admission limiter across Cluster and NodePool controllers (and
per-account limits if needed) to pace AWS-check starts. Add stable jitter to
each check's periodic schedule. Write probes must be safe to retry and clean up
after cancellation. Do not persist in-progress checkpoints for resume or a
next-run schedule for the initial design; persisted per-step status is
diagnostic and supplies last-check timestamps for periodic scheduling. The
separate
network-verifier job flow has its own persisted job state and restart behavior.
Per-step checkpointing or resume using the `PreflightResource` may be considered
later; it is explicitly out of scope for the initial implementation.

### Orphaned write-probe resources

Normal write probes should always attempt cleanup with a bounded context that
survives cancellation of the main check. That is insufficient for process
termination, host loss, or an AWS timeout after resource creation, so design a
separate orphan-recovery path as well.

- Tag every temporary resource at creation with a reserved marker such as
  `seaplane.io/preflight-probe=true`, a unique run ID, the owning Cluster or
  NodePool UID, and creation time. Use tag-on-create where AWS supports it.
  For APIs that cannot tag at creation, use a deterministic, reserved resource
  name as a fallback and tag immediately after creation.
- Before cleanup, discover only resources carrying the exact Seaplane marker
  and delete only those at least two hours old. Enforce a hard maximum lifetime
  for every write probe that is shorter than this threshold. For long-running
  network-verifier jobs, also check persisted running state/lease so an active
  probe is never mistaken for an orphan; a longer lease may defer cleanup.
- **Security caveat:** customer-account tags are customer-editable and
  forgeable. The marker tag is only a discovery hint, never sufficient
  authority to delete a resource. Before deletion, match the candidate to a
  known preflight run/resource record or another independently validated
  Seaplane-owned identity (such as a reserved run-specific name and recorded
  resource relationship). Resolve the crash window where a resource is
  created but its ID is not yet recorded before enabling cleanup.
- Implement resource-specific discovery and dependency-ordered deletion for
  each probe type (for example, terminate instances before deleting their
  network resources). If ownership or staleness cannot be proven, leave the
  resource untouched and report the cleanup failure.
- Do not make an unfiltered account-wide scan for every Cluster and NodePool
  check. Prefer a bounded, account-scoped cleanup pass or a dedicated janitor
  using the same assumed Installer Role. If cleanup or rate limiting must be
  single-flight per account, coordinate across operator replicas/shards; a
  process-local mutex or limiter is insufficient. Otherwise, explicitly make
  concurrent cleanup idempotent and safe.
- Verify that the Installer Role policy allows both the required marker-tag
  discovery and deletion operations for every temporary resource type. Emit
  metrics and logs for resources found, deleted, and failed; never log
  credentials.
- Retain the PreflightResource's run/artifact records until cleanup succeeds or
  a durable janitor has accepted ownership. On target deletion, the target
  finalizer must wait for that cleanup or handoff before the associated
  PreflightResource and its run metadata are removed.

The exact tag keys and discovery APIs, whether cleanup is a preflight sub-step
or a dedicated account-scoped reconciler, and whether account-level coordination
uses a distributed lease or concurrent idempotent operations remain design
decisions. The two-hour minimum is the default stale-age threshold; it can be
increased if any probe's hard lifetime requires it. This recovery is
intentionally idempotent and separate from the pass/fail result of each
validation.

### Status contract

Add a stable condition for each applicable check and one aggregate condition
(for example, `Preflight`) to Cluster and NodePool status. Check condition types
are part of the customer-facing API contract and must have stable names,
reasons, and sanitized messages.

| Status    | Meaning                                                                                                    |
| --------- | ---------------------------------------------------------------------------------------------------------- |
| `Unknown` | The check is pending/running or a transient/internal error prevented a result for the current fingerprint. |
| `True`    | The check passed for the observed fingerprint.                                                             |
| `False`   | The check completed and found an actionable conformance failure.                                           |

Set `ObservedGeneration` on each condition and distinguish transient/internal
errors from actionable conformance failures. Transient/internal errors use
`Unknown` with a retryable reason; actionable conformance failures use `False`.
Provide concise, actionable messages without credentials or sensitive AWS
response payloads. A blocking check in `Unknown` continues to hold admission
until a current-fingerprint pass. `LastTransitionTime` does not record every
successful periodic run; decide whether the target API needs an explicit
`LastCheckTime`.

Record non-applicable checks as `Skipped` internally and omit their public
conditions; exclude them from the aggregate. For applicable checks, map
success to `True`, conformance failure to `False`, and pending/retryable error
to `Unknown`. The aggregate is `False` if any applicable check has a
conformance failure; otherwise it is `Unknown` if any applicable check is
pending/running or retrying; otherwise it is `True`.

The aggregate condition summarizes all applicable check results but does not
itself gate provisioning. A normal conformance failure in one step should not
cancel independent checks: collect per-step results and let each configured
gate use its own status. Cancel remaining work only for overall timeout,
target/dependency revision changes, or controller shutdown. This differs from
the legacy errgroup behavior, which returns the first error and cancels its
concurrent group.

Condition updates must preserve other Cluster/NodePool conditions, use
conflict-safe status updates, and avoid marking a new spec generation as
preflight-passed based on a result for an older generation.

### Per-step provisioning gates

The current operator has two target-level admission points, not a general
multi-stage provisioning model:

- **Cluster:** `ClusterReconciler` writes a bundle of ApplyDesires. All
  applicable Cluster checks configured as `Block` must pass for the current
  fingerprint before the first ApplyDesire in that bundle is written.
- **NodePool:** `NodePoolReconciler` writes the NodePool ApplyDesire. All
  applicable NodePool `Block` checks must pass, and any parent Cluster apply
  gate must already be released for the current Cluster revision.

Preflight is not a global prerequisite for every check or every later
reconciliation. `Observe` checks always publish conditions but never hold
ApplyDesires. Not-applicable checks do not block. A failed or pending `Block`
check holds its target's initial ApplyDesire admission.

Bind `applyGateReleasedRevision` to the target revision, the current blocking
policy fingerprint, and the set of blocking check identities/versions and
successful input fingerprints that released it. Before the first ApplyDesire
for a revision is written, require that snapshot to match the current blocking
policy and live input fingerprints; a newly added or changed `Block` check must
pass before it can release the gate.

Record when ApplyDesire submission has started for that revision. Once the
Cluster bundle or NodePool ApplyDesire has been submitted, keep the release
sticky for that revision: later periodic failures or policy changes report
conditions but do not retroactively hold completed provisioning. A changed
target revision (or relevant parent Cluster/account-access revision for a
NodePool) requires a new gate release. Gate checks use each step's fingerprint
computed from live target and dependency inputs, not the aggregate
`Preflight=True` condition. Finer-grained gates between subsets of Cluster
resources would require splitting the current Cluster ApplyDesire bundle and
are out of scope.

### Cluster versus NodePool scope

- Cluster checks use the Cluster’s region, network, shared-VPC, role and
  HostedCluster configuration. Examples include account/role permissions,
  AZs, network/CIDR and DNS consistency, shared-VPC/subnet ownership,
  security-group configuration, cluster tags and cluster-level quotas.
- NodePool checks use the NodePool’s instance type, AMI, subnet, instance
  profile, architecture and tags, together with parent Cluster account,
  region, networking and roles. Examples include instance-type availability,
  subnet compatibility, AMI visibility, worker profile/role assumptions and
  applicable worker quotas.
- Avoid repeating all account-wide checks for every NodePool. Keep shared
  checks on the Cluster and pool-specific checks on the NodePool.
- A Cluster generation change can invalidate NodePool check inputs. Ensure
  NodePools are re-enqueued when relevant parent Cluster fields change, even
  though NodePool reconciliation currently discovers the parent by lookup and
  otherwise relies partly on periodic requeue.
- If installer-role association is stored in a separate account-access
  resource, changes to that resource must also invalidate and re-enqueue every
  referencing Cluster and NodePool. The gate must compare against the live
  association revision, not wait for that re-enqueue to update cached
  PreflightResource input.
- As soon as a parent or access-resource revision changes, mark affected
  NodePool step conditions `Unknown`/stale until the new revision is checked;
  do not leave a previously `True` condition appearing current while the
  asynchronous check is pending.
- The old check list includes legacy Classic ROSA and OCM-only validations.
  Maintain an explicit applicability matrix for Seaplane’s HCP/HyperShift
  configuration; do not silently port Classic checks or OCM-only feature
  toggles.
- Recommendation: run the preflight workflow for every Seaplane AWS Cluster and
  NodePool, while marking checks that do not apply as skipped internally rather
  than using the legacy `Managed`/CCS selection. Confirm that product scope
  before implementation.

### Customer AWS account access

The operator will access the customer account by assuming the customer's
installer role. The unresolved design question is where Seaplane stores the
association between a customer account and that role. `CreatorARN` is identity
metadata, not credentials. The operator's regional Pod Identity/IRSA permissions
and the OIDC signing-key cross-account secret reader do not by themselves grant
permission to inspect the customer's account.

#### Bind the role to the target account

`Cluster.spec.accountId` is service-set from the authenticated account context;
it is the authoritative owner account for preflight. Before calling
`sts:AssumeRole` or making any customer-account API call, resolve the
Installer Role association and require the 12-digit account in its ARN to
equal the Cluster's `spec.accountId` and account namespace/label. For Option 2,
also require the account-access resource's account ID to match. Reject a
mismatch locally before probes or cleanup. A NodePool has no independent
Installer Role: resolve it through the UID-validated parent Cluster and perform
the same checks before any AWS operation.

This account-ownership check is separate from the ExternalId confused-deputy
control; ExternalId does not prove that the role belongs to the Cluster's
account. Use a service-owned ExternalId, stable for the shared access
association rather than an individual request/session. Settle whether its
uniqueness scope is an AWS account or an AWS-account/Red Hat organization
association, and store/resolve it service-side with the Installer Role
association.

#### Option 1: store the installer-role association on each Cluster

Add the installer role ARN (or a reference to it) to Cluster spec, following
the per-cluster AWS role association used by `uhc-clusters-service`. The
preflight reconciler reads that association and assumes the role for the
Cluster's checks; NodePool checks resolve it through their parent Cluster.

- **Advantages:** association is explicit alongside the Cluster's AWS
  configuration; no new resource or account-level lifecycle is needed; simple
  to resolve in the Cluster and NodePool reconciliations.
- **Tradeoffs:** the same role ARN is repeated across Clusters in one AWS
  account; changing or rotating the association may require updating each
  Cluster; API write-mode, mutability, and whether the ARN is customer-visible
  need to be defined.

#### Option 2: store the association in a separate account-scoped resource

Add a dedicated resource representing customer AWS account access, containing
the account identity and installer role ARN. Clusters reference that resource,
and NodePools resolve the association through their parent Cluster.

- **Advantages:** one association can be shared across Clusters in the same
  AWS account; role rotation and account-level access status have a single
  management point; avoids duplicating the ARN in every Cluster.
- **Tradeoffs:** requires a new API resource and lifecycle, reference and
  ownership rules, authorization, uniqueness/account matching, deletion
  protection while referenced, and reconciliation behavior when the role
  association changes.

Neither option stores AWS credentials or STS session tokens. Both require the
operator to have permission to call `sts:AssumeRole`, the customer Installer
Role's trust policy to authorize the operator, and the V1 Installer Role
managed policy to remain in place initially. That policy is not read-only:
legacy checks include temporary-resource probes, and the separate network
verifier runs AWS network tests using the Installer Role. Audit actual policy
usage later before considering a reduced policy. Also define STS session
lifetime, credential caching and refresh, regional endpoints,
optional-permission behavior, and how role/account mismatches and
authentication/authorization failures appear in conditions.

The Seaplane preflight gate must prove that the customer Installer Role's trust
policy permits only the configured Seaplane operator AWS role (the service
principal supplied by its Pod Identity/IRSA configuration) to assume it, and
that every such `sts:AssumeRole` allow requires the exact service-owned
`sts:ExternalId`. A successful `AssumeRole` call alone does not prove this: it
only shows that at least one applicable allow admitted that request; a second
unconditional or broader allow could still exist. The checker must inspect the
entire trust policy and reject wildcard or alternate principals and any
unconditional/incorrectly conditioned allow.

The check runs after the local Installer Role ARN/account-ID match and a
successful `AssumeRole` using the expected ExternalId. It then calls IAM
`GetRole` with the assumed customer Installer Role session and validates the
returned `AssumeRolePolicyDocument`. The authorized identity for this read is
the assumed Installer Role. The operator's Pod Identity/IRSA role is the
principal being validated in the customer role's trust policy; it is not the
identity used for `GetRole`. The OIDC secret-reader path is unrelated.

The checked-in V1 policy template
`clusters-service: configs/policies/sts_installer_permission_policy.json`
grants `iam:GetRole` with `Resource: "*"`. The mapping in
`clusters-service: pkg/config/aws/sts_managed_policies.go` maps the Classic and
HyperShift installer policy names to the AWS managed `ROSAInstallerPolicy`.
Verify deployed policy versions retain this permission. If `GetRole` is denied,
fail this mandatory Block check with an actionable condition; before supporting
policy versions without it, update the approved Installer Role policy or define
a separately authorized trust-policy read path. Do not silently fall back to
the operator's AWS identity.

The legacy HyperShift instance-profile quota check can create and delete a
temporary IAM instance profile. Treat it and the separate network verifier as
write probes: bound execution and concurrency, clean up on success, failure,
and cancellation, and avoid orphaned resources. Surface their results
asynchronously; no legacy blocking-behavior toggle is needed for this Seaplane
flow.

Never persist AWS credentials or session tokens in Cluster/NodePool spec,
status, events, or logs.

## Compatibility and rollout

The HTTP create/update API will no longer synchronously reject a customer
account configuration based on AWS state. It will accept locally valid input,
return the persisted resource, then expose asynchronous per-step and aggregate
preflight conditions. Static syntax and shape validation should remain
synchronous. Provisioning is not globally gated: a failed step holds the
target's initial ApplyDesire admission only when that step's policy is `Block`;
all other steps are `Observe`.

An initial rollout may force all non-mandatory checks to `Observe` while the
credential path and applicability matrix are validated. The service-owned
`ExternalId` check remains `Block` throughout because it is a hard provisioning
requirement. Later, selected checks can be switched to `Block` for Cluster or
NodePool ApplyDesire admission; there is no single switch that makes the entire
preflight suite a global provisioning gate. Document this contract for API
consumers and ensure waiters/clients can observe the conditions.

## Decisions to settle before implementation

1. Choose where to store the customer-account-to-installer-role association:
   on each Cluster (Option 1) or in a separate account-scoped resource
   (Option 2).
2. Finalize stable per-check condition types/reasons, aggregate semantics, and
   whether a `LastCheckTime` is needed.
3. Define per-check input-change and periodic schedules, transient retry
   intervals, which write probes may run periodically, concurrency limits, and
   whether these are flags or operator configuration.
4. Assign every check an `Observe` or `Block` policy and, for blocking checks,
   whether it gates Cluster admission, NodePool admission, or both. Confirm
   which non-mandatory checks start in `Observe`; preserve the mandatory
   `ExternalId` Cluster gate in every rollout mode.
5. Confirm that preflight applies to every Seaplane AWS Cluster/NodePool rather
   than mapping the legacy unmanaged/CCS predicate.
6. Approve the check catalog and Cluster/NodePool applicability matrix;
   identify checks that are intentionally omitted, deferred, moved to
   provisioning, or still owned by API validation.
7. Define the durable ownership evidence for orphan cleanup; a matching tag
   alone must never authorize deletion.
8. Choose the service-owned ExternalId uniqueness scope (AWS account or
   AWS-account/Red Hat organization association); always enforce the separate
   Installer Role ARN-to-Cluster-account match before STS.
