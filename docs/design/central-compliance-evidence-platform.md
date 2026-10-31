# Central Compliance Evidence Collection Platform

**Last Updated Date**: 2026-10-20

## Summary

FedRAMP continuous-compliance evidence collection runs as a `complyctl`-based
engine in the **central AWS account**, executed as **scheduled batch runs
(Amazon EventBridge Scheduler → Amazon ECS Fargate tasks)** that write OSCAL
evidence to a **pluggable evidence sink**. The platform covers **all FedRAMP
KSIs**, not any single control family. It is explicitly not run per-region, not
inside the Regional or Management Clusters, and not on a dedicated EKS cluster.

## Context

- **Problem Statement**: FedRAMP requires continuous, objective evidence for
  every Key Security Indicator. We need a single, auditable home for the
  automation that produces that evidence across the fleet.
- **Constraints**: The evidence-producing system is itself in-scope for the
  FedRAMP authorization boundary, so its own attack/assessment surface must stay
  small. It must be decoupled from the customer-facing control planes. The
  evidence destination is interim: Red Hat will supply an "evidence locker," so
  the sink must be swappable.
- **Assumptions**: The central account already acts as the fleet's CI/CD control
  plane and can assume roles into the regional and management accounts, giving
  collectors cross-account reach for cloud-posture evidence. `complyctl` is a
  batch engine: one run orchestrates many assessment plans/providers and exits.
  The central account has no VPC today, so the Fargate tasks require net-new
  networking — allowlisted egress to the few required external endpoints (GitHub
  API, package registries) and VPC endpoints for AWS APIs, so a compromised
  dependency has no open path to exfiltrate credentials.

## Alternatives Considered

1. **Per-region deployment**: Replicate the collector in every region (~40 prod
   regions). Rejected — enormous multiplication for a fleet-global job with no
   isolation benefit.
2. **Inside the Regional/Management Clusters**: Rejected — couples compliance
   tooling to the customer-serving control planes, enlarging their blast radius
   and FedRAMP assessment scope for no operational gain. RC/MC also carry strict
   private-networking invariants this workload has no reason to touch.
3. **Dedicated central EKS cluster** (EKS + Karpenter + ArgoCD + ECS bootstrap,
   mirroring RC/MC): Rejected — it would be the first central compute cluster
   (none exists today), inflates the assessment surface of the evidence tool
   itself (node patching, FIPS AMIs, Karpenter CVEs, ArgoCD), needs net-new
   region-nested config/pipeline plumbing, and is heavily over-sized for
   scheduled batch work.
4. **Central EventBridge + ECS Fargate serverless batch** (chosen).

## Design Rationale

- **Justification**: What grows with "all KSIs" is the Gemara policy content
  (L1/L2/L3) and the provider/collector set that `complyctl` orchestrates — not
  the compute footprint. A scheduled containerized engine is the right-sized
  substrate, has no idle compute cost, and keeps the smallest possible surface to
  describe in the SSP. The design composes two primitives already proven
  independently in this codebase — EventBridge Scheduler (used by ZOA) and ECS
  Fargate (used by private-bootstrap and the current ECS SSM bastions) — and
  gives CloudTrail/CloudWatch audit trails for free. The scheduler-triggered
  Fargate batch combination itself is new here.
- **Comparison**: This follows the same serverless-first instinct as the ZOA
  architecture, whose own control plane is deliberately not a Kubernetes
  workload — rather than the heavyweight RC/MC cluster pattern, which is earned by
  persistent, HA, customer-facing services this workload is not. Unlike ZOA, the
  compliance platform has no EKS dependency at all.

## Consequences

### Positive

- Minimal, ephemeral footprint; no idle compute cost; small, easily-assessed
  control surface for the evidence system itself.
- Evidence sink is behind a seam, so the move to the Red Hat evidence locker is
  a backend swap, not an engine change.
- Sits inside the already-authorized central boundary, reusing its cross-account
  trust roles and audit logging.

### Negative

- The real work is greenfield policy authoring (translating KSIs into Gemara
  catalogs) and building per-KSI collectors — this ADR only fixes the runtime.
- Orchestration complexity grows with the collector set; a later step to AWS
  Step Functions may be warranted for multi-step/fan-out evidence pipelines.
- No in-cluster monitoring stack is inherited; observability must be built on
  CloudWatch (see below).

## Observability & Alerting

Mission-critical. For continuous monitoring, **a collection gap is itself a
compliance failure** — a silently missed run is indistinguishable to an assessor
from a lapsed control. Three alert classes are surfaced via CloudWatch alarms
into the platform's existing alerting/notification path:

- **Run liveness and coverage (dead-man's switch)**: alert on the _absence_ of a
  successful scheduled run within its expected window, not only on explicit task
  failures. "Successful" means full expected coverage — a per-run manifest must
  account for every target (KSI × account × region × provider); a task that exits
  cleanly but silently skips targets is a collection gap and alarms like a missed
  run.
- **Evidence delivery**: alert on any failure (including partial writes) to
  persist evidence to the sink.
- **Compliance regression**: alert when a KSI / assessment-requirement
  transitions from MET to NOT MET between runs. The comparison relies on stable
  assessment-requirement identifiers and a durable record of the prior run held
  independently of the (swappable) evidence sink, so sink migration never blinds
  regression detection.

## Cross-Cutting Concerns

### Resiliency

Central collection makes the central account a single failure domain for every
region's evidence. This is acceptable because runs are stateless, repeatable
batch that reconstruct current-state evidence: a central scheduler, cross-account
trust, or connectivity failure yields a _missed_ run — caught by the run-liveness
dead-man's switch above — rather than lost or corrupted evidence, and recovery is
a re-run or backfill, not a repair.

### Security

- The evidence pipeline runs under a dedicated IAM role with least-privilege,
  read-only cross-account access to the resources it inspects.
- Separation of duties is a property of the _other_ principals, not of the
  compliance role: scoping the compliance role cannot stop a broad central-account
  pipeline/admin role from reading its secrets, rewriting its task definition, or
  tampering with its output. It must be enforced against all non-compliance
  principals — via a dedicated account/OU for the platform, or resource policies
  (on its KMS key, secrets, and evidence bucket) and SCPs, which can deny
  unrelated principals. Permission boundaries do not fit here: they only cap the
  permissions of the principal that carries them, so they cannot fence other
  principals away from the platform's KMS key, secrets, task and execution roles,
  task definition, collector image, schedule, alarms, and evidence bucket. The
  deployment path that maintains these resources is itself
  distinct from the collection role and audit-logged, so CI/CD cannot silently
  change what the platform collects or where evidence lands. The mechanism is an
  open implementation choice.
- Evidence integrity (FedRAMP AU-9): encryption and retention are not
  tamper-resistance. The evidence sink is write-once — S3 Object Lock (compliance
  mode) plus versioning, so neither the writer nor an admin can overwrite or delete
  evidence within its retention period — and each run emits an integrity manifest
  (hashes) so downstream tampering is detectable.
- No secret material in output: collectors capture posture metadata, not raw
  secret values, and output is scrubbed before it is written or shipped to the
  external locker; verbose/debug logging (which can echo auth headers) is disabled.

### Secret management

Secrets live in AWS Secrets Manager / SSM Parameter Store (KMS-encrypted) — the
same backing stores the platform already uses (e.g. `seaplane-db`, PagerDuty).
RC/MC reach these stores through External Secrets Operator; being serverless, this
platform fetches secrets from the same stores at runtime via the task role (AWS
SDK) rather than through ESO. The GitHub App private key is fetched, immediately
exchanged for a short-lived installation token, and discarded — it is not injected
as an environment variable (env vars are inherited by every `complyctl` provider
subprocess and leak through crash dumps), never baked into images or task
definitions, and never written to logs or evidence output.

The design minimizes long-lived secrets by preferring credentials that are
short-lived by construction:

- **GitHub access uses a GitHub App, not a personal access token.** The App is
  least-privilege and read-only, installed only on the required orgs/repos. The
  engine mints a short-lived installation token (~1h TTL) per run from the App's
  private key, so there is nothing to rotate between runs. (The central account's
  existing CodeStar connection serves CodeBuild's source checkout and is not
  usable for the engine's API calls.)
- **Cross-account AWS access uses STS `AssumeRole`** — already how the central
  account reaches the regional/management accounts — which is ephemeral and
  stores no secret.

Durable secrets — the GitHub App private key today, the Red Hat evidence-locker
credential later, and more as providers are added — live in Secrets Manager with
scheduled rotation; the GitHub App supports multiple active keys for zero-downtime
rollover. The aim is to keep this set as small as possible, not to fix it. Access
is least-privilege (the task role reads only its own secret ARNs and decrypts only
its own KMS key); keeping other principals away from these secrets is covered by
the separation-of-duties isolation above.
