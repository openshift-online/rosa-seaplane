# Provisioning a Development Environment

Ephemeral environments are short-lived, isolated stacks for developing and testing the ROSA Seaplane. All commands run inside a container on your local machine (podman or docker) and interact with shared development AWS credentials (central, regional, management accounts).

Each environment gets a unique ID that prefixes all provisioned resources, keeping environments isolated from each other. The ephemeral provider creates a managed clone of your remote branch and uses it to drive provisioning and ArgoCD syncs. To push subsequent changes into a running environment, use [Resync](#resync).

## Prerequisites

The following tools must be in `PATH` for all ephemeral environment commands:

| Tool              | Purpose                                     |
| ----------------- | ------------------------------------------- |
| `git`             | Repository operations                       |
| `python3`         | Config rendering                            |
| `uv`              | Python script runner (SAML credentials)     |
| `fzf`             | Interactive selection menus                 |
| `podman`/`docker` | Running the ephemeral environment container |

Port forwarding additionally requires `aws` and `lsof`.

### AWS Account Setup

By default, scripts look for account ID files in the `rosa-seaplane-internal` sibling repo:

- **Ephemeral (dev)**: `../rosa-seaplane-internal/infra/accounts/dev/accounts.json`
- **Integration**: `../rosa-seaplane-internal/infra/accounts/int/accounts.json`

If you have the internal repo checked out alongside this one, no extra setup is needed.

To override, set the env vars `RRP_ACCOUNTS_DEV` or `RRP_ACCOUNTS_INT` to point to a different file. The expected format is:

```json
{
  "admin": "<admin-account-id>",
  "central": "<central-account-id>",
  "rc": "<rc-account-id>",
  "mc": "<mc-account-id>",
  "customer": "<customer-account-id>"
}
```

(Integration accounts omit `admin`.)

Alternatively, set `RRP_AWS_PROFILES_PRESET=1` to skip the built-in credential setup entirely and manage your own AWS profiles (profiles must be named `rrp-ephemeral-{central,rc,mc,customer}` for ephemeral or `rrp-int-{rc,mc,customer}` for integration).

## Provision

> ⚠️ _Ensure your changes are pushed to the remote branch before provisioning — the environment is built from the remote ref, not your local working tree._

```bash
# Interactive — fzf picker for remote and branch
make ephemeral-provision

# Explicit — skip the picker
make ephemeral-provision REPO=owner/repo BRANCH=my-feature
```

On success the command prints the environment ID as well as guidance to interact with the environment.

The region is derived from the environment config (see [Customizing Your Environment](#customizing-your-environment)). By default it provisions in `us-east-1`.

To view and interact with provisioned environments at a later point in time, see [List Environments](#list-environments).

## Resume Failed Provisioning

If provisioning fails after the ephemeral branch has been created, resync and resume the same environment without creating another branch or environment state record:

```bash
make ephemeral-provision-resume ID=6bd2d3d7
```

By default, resume first resets the ephemeral branch to the latest source branch, reapplies `.ephemeral-env/` overrides, renders, and force-pushes the result. It then reuses existing Terraform state, CodePipelines, and CodeBuild resources and retries the infrastructure executions. Use `RESYNC=false` to resume from the existing remote branch without changing it:

```bash
make ephemeral-provision-resume ID=6bd2d3d7 RESYNC=false
```

Ephemeral CodePipeline push triggers remain enabled. A push matching a pipeline's
branch and file-path filters starts that pipeline, and the provider adopts the
execution for the pushed SHA. On initial creation, the provider adopts the
pipeline's automatically started execution. A resume without a matching push
reuses an active execution at that SHA or starts a retry if the pipeline is idle.
See [CodePipeline Cluster Lifecycle](design/codepipeline-cluster-lifecycle.md)
for the trigger and execution details.

Automatic resync stops before the force-push if the environment has active CodePipeline executions or a platform-image CodeBuild build, preventing concurrent infrastructure changes. Wait for those executions to finish and retry, or use `RESYNC=false` if the existing branch should be retained.

## Customizing Your Environment

By default, ephemeral environments use the preset in `config/ephemeral/` (bastion enabled, single MC in `us-east-1`). You can replace this config entirely for your local development by creating a `.ephemeral-env/` directory in the repo root.

### Structure

The `.ephemeral-env/` directory must mirror the `config/<env>/` structure:

```
.ephemeral-env/
├── defaults.yaml        # Environment-level defaults (optional)
└── us-east-1.yaml       # Region config (exactly one region file required)
```

This directory is gitignored — it only affects your local machine.

### Constraints

- Exactly **one region file** (besides `defaults.yaml`) must exist — the ephemeral provisioner deploys to a single region.
- The region file must define **`provision_mcs`**. The default ephemeral topology contains one management cluster (`mc01`), while additional entries can be rendered when the corresponding account and runtime support are available.
- AWS account IDs are injected automatically from credentials — do not set `aws.account_id` or `aws.management_cluster_account_id`.

### Examples

Use default topology but enable bastion and change instance families:

```yaml
# .ephemeral-env/defaults.yaml
regional_cluster:
  enable_bastion: true
  node_instance_families: ["m7i"]

management_cluster_defaults:
  enable_bastion: true
  node_instance_families: ["m7i"]
```

```yaml
# .ephemeral-env/us-east-1.yaml
provision_mcs:
  mc01: {}
```

Provision in a different region:

```yaml
# .ephemeral-env/us-east-2.yaml
provision_mcs:
  mc01: {}
```

Enable write access to SRE tools (Grafana, ArgoCD):

```yaml
# .ephemeral-env/defaults.yaml
regional_cluster:
  enable_write_sre_tools: true
```

```yaml
# .ephemeral-env/us-east-1.yaml
provision_mcs:
  mc01: {}
```

By default (`enable_write_sre_tools: false`) Grafana is provisioned with anonymous
Viewer access and ArgoCD disables the admin account with anonymous read-only access.
Setting this flag to `true` restores admin access to both. This flag can only be set
to `true` for ephemeral environments — `render.py` enforces this at render time.

### Applying Changes

Overrides are applied during `provision` and `resync`. To update a running environment after editing `.ephemeral-env/`:

```bash
make ephemeral-resync ID=<id>
```

## List Environments

Lists environments you have provisioned from your local machine. State is cached in the `.ephemeral-envs` file in the repo root — you can clear it at any time by deleting the file.

To interact with a previously provisioned environment, list your environments and pass the ID to the relevant command (e.g. `make ephemeral-shell ID=<id>`).

```bash
make ephemeral-list
```

Example:

```
Ephemeral environments:

ID           REPO                                          BRANCH                    REGION       STATE                  CREATED              API_URL                                                      RHOBS_API_URL
------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- ------------------------------------------------------------ ------------------------------------------------------------
6bd2d3d7     typeid/rosa-seaplane                 ROSAENG-143               us-east-1    ready                  2026-03-19T10:14:23Z https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod  https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod

To clear list: rm .ephemeral-envs
```

## Shell Access

Opens an interactive shell pre-configured with regional AWS credentials to interact directly with the API Gateway.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-shell

# Explicit
make ephemeral-shell ID=6bd2d3d7
```

Example:

```
Resolving base credentials...
Fetching GitHub token from Secrets Manager...

ROSA Seaplane shell

API Gateway: https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod
Region:      us-east-1

Example commands:
  awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live

[root@df2f729c21c2 /]# awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live
{"status":"ok"}
```

## Bastion Access

Connect to a bastion ECS task to access the Kubernetes API of the ephemeral environment's Regional Cluster (RC) or Management Cluster (MC). The bastion runs inside the cluster's VPC and has `kubectl` pre-configured with cluster-admin access.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

```bash
# Regional Cluster bastion
make ephemeral-bastion-rc

# Management Cluster bastion
make ephemeral-bastion-mc

# Explicit environment selection
make ephemeral-bastion-rc ID=6bd2d3d7
```

This resolves AWS credentials, starts a bastion ECS task if none is running, waits for the execute command agent, and drops you into an interactive shell on the bastion. From there you can run `kubectl` commands against the cluster:

```
==> Bastion task ready
    ECS cluster: eph-f16cec-regional-bastion
    Task ID:     683c1f0af6ae4e1bba3552f2c8215bd3

==> Connecting to bastion...

bash-5.2# kubectl get nodes
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-1-42.ec2.internal    Ready    <none>   2h    v1.31.4-eks-aeac579
```

The bastion task stays running until explicitly stopped or until the environment is torn down (teardown automatically cleans up running bastion tasks).

## Port Forwarding

Forward ports from cluster-internal services to your local machine through the bastion, without needing an interactive shell. This is useful for accessing ArgoCD and Prometheus UIs directly in your browser.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

### Interactive service selection

```bash
# Select services interactively (fzf multi-select) — Regional Cluster
make ephemeral-port-forward-rc

# Select services interactively — Management Cluster
make ephemeral-port-forward-mc

# Explicit environment selection
make ephemeral-port-forward-rc ID=6bd2d3d7
```

### Forward all services at once

```bash
# Forward all available services — Regional Cluster
make ephemeral-port-forward-rc-all

# Forward all available services — Management Cluster
make ephemeral-port-forward-mc-all
```

Available services per cluster type:

| Service      | RC  | MC  | Local address          |
| ------------ | --- | --- | ---------------------- |
| ArgoCD       | yes | yes | https://localhost:8443 |
| Prometheus   | yes | yes | http://localhost:9090  |
| Thanos Query | yes | no  | http://localhost:10902 |
| Thanos Ruler | yes | no  | http://localhost:10903 |
| Loki         | yes | no  | http://localhost:13100 |
| Alertmanager | yes | no  | http://localhost:9093  |
| Grafana      | yes | no  | http://localhost:3000  |

The command fetches the ArgoCD admin password automatically and prints it to the terminal. Port forwards remain active until you press `Ctrl+C`.

Prerequisites: `aws`, `fzf`, and `lsof` must be in `PATH`.

## Run E2E Tests

Run the end-to-end test suite against one of your development environments:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-e2e

# Explicit
make ephemeral-e2e ID=6bd2d3d7
```

By default, tests are cloned from the `main` branch of `rosa-seaplane-api`. Use `E2E_REF` and `E2E_REPO` to run against a different branch or fork:

```bash
# Run tests from a feature branch
make ephemeral-e2e ID=6bd2d3d7 E2E_REF=my-feature-branch

# Run tests from a fork
make ephemeral-e2e ID=6bd2d3d7 E2E_REPO=https://github.com/my-fork/rosa-seaplane-api.git E2E_REF=my-feature-branch
```

To keep the cluster and infrastructure alive after a test run (useful for debugging failures), set `E2E_SKIP_CLEANUP`:

```bash
make ephemeral-e2e ID=6bd2d3d7 E2E_SKIP_CLEANUP=1
```

This skips both the cleanup-labeled ginkgo specs and the `DeferCleanup` safety net, so the HCP cluster, VPC, IAM, and OIDC resources survive for investigation. Remember to tear them down manually afterwards with `make ephemeral-teardown` or by re-running without the flag.

### ZOA testing

ZOA automated tests live in [`rosa-seaplane-zoa`](https://github.com/openshift-online/rosa-seaplane-zoa); this repo clones and runs them — it does not duplicate test logic. For laptop operator workflows, see [ZOA](#zoa).

- **`make ephemeral-e2e`** — runs platform e2e plus required ZOA **smoke** unless `E2E_SKIP_ZOA=true`. `ci/e2e-tests.sh` fails if neither RC nor MC Lambda URL resolves; the local Make wrapper requires both URLs before starting tests, including when ZOA is skipped.
- **`make ephemeral-zoa-e2e`** / **`make ephemeral-zoa-e2e-smoke`** — ZOA **full** or **smoke** only; same clone-by-ref pattern as API e2e (`ZOA_REF` / `ZOA_REPO`).

```bash
make ephemeral-zoa-e2e ID=6bd2d3d7
make ephemeral-zoa-e2e ID=6bd2d3d7 ZOA_REF=my-branch ZOA_REPO=https://github.com/my-fork/rosa-seaplane-zoa.git
make ephemeral-zoa-e2e-smoke ID=6bd2d3d7
make ephemeral-zoa-e2e-smoke ID=6bd2d3d7 ZOA_REF=my-branch ZOA_REPO=https://github.com/my-fork/rosa-seaplane-zoa.git
```

These targets exercise the Lambdas already deployed in the environment; they do not rebuild or redeploy ZOA images. Test suite details: [`rosa-seaplane-zoa/docs/e2e-testing.md`](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/docs/e2e-testing.md).

## Dump Environment

Collect Kubernetes diagnostic logs (`oc adm inspect`) and PostgreSQL database state from the RC and/or MC clusters in an ephemeral environment. Data is gathered by the log-collector ECS Fargate task, uploaded to S3, and downloaded locally.

For the RC, this also dumps the `kubernetes_resources` table from Aurora PostgreSQL — producing a tabular summary (`resource-summary.txt`) and per-resource JSON files under `db-state/resources/<Kind>/<name>.json`.

```bash
# Collect from both RC and all MCs
make ephemeral-dump-env

# Collect from RC only
make ephemeral-dump-env CLUSTER=rc

# Collect from MCs only
make ephemeral-dump-env CLUSTER=mc

# Explicit environment selection
make ephemeral-dump-env ID=6bd2d3d7
```

Output is written to `/tmp/<eph-prefix>-logs-<timestamp>/`. The RC output includes a `db-state/` subdirectory with the database dump. In CI, data is automatically collected on e2e test failure with `S3_ONLY=true` — results are left in S3 (to avoid publishing sensitive data) and the S3 URIs are printed for manual retrieval.

> ⚠️ _Bastion must be enabled in your environment config (`enable_bastion: true` in `defaults.yaml`). The default ephemeral preset already has it enabled._

## Resync

The ephemeral environment runs from an ephemeral-provider managed clone of your branch. If you push additional changes to your remote branch after provisioning (e.g. updating a Helm chart or Terraform module), the environment won't pick them up automatically — you need to resync so the cloned branch is updated and ArgoCD syncs the changes.

Resync also re-applies the environment config, so changes to `.ephemeral-env/` are picked up alongside code changes.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-resync

# Explicit
make ephemeral-resync ID=6bd2d3d7
```

## ZOA

[Zero Operator Access](https://github.com/openshift-online/rosa-seaplane-zoa) is how you operate a running environment from your laptop: discover deployments and targets, start audited boundary sessions, and run trusted actions from inside the boundary. Use it after [provision](#provision) (and [resync](#resync) when you change ZOA images, Terraform, or invoker trust on your branch).

1. Request ZOA operator roles in app-interface (see onboarding in the internal repo).
2. `rh-aws-saml-login` into the central account for dev — [ZOA operator access](https://github.com/openshift-online/rosa-hyperfleet-internal/blob/main/docs/onboarding/zoa-operator-access.md) in the `rosa-seaplane-internal` sibling repo lists resolved commands per environment.
3. Build or install the `zoa` CLI from [rosa-seaplane-zoa](https://github.com/openshift-online/rosa-seaplane-zoa).

```bash
zoa deployments
zoa targets <deployment-id>
zoa session start <deployment-id> <target-id> --reason <JIRA-or-PD>
```

## Swap Branch

Redirect a running environment to a different branch or fork without tearing it down and reprovisioning. The environment identity (and its managed CI branch) is preserved — only the source branch being tracked changes. After swapping, a resync runs automatically to apply the new branch.

```bash
# Interactive — fzf pickers for environment and branch selection
make ephemeral-swap-branch

# Explicit — swap to a branch on the same repo
make ephemeral-swap-branch ID=6bd2d3d7 NEW_BRANCH=my-other-feature

# Explicit — swap to a branch on a different fork
make ephemeral-swap-branch ID=6bd2d3d7 NEW_BRANCH=my-feature NEW_REPO=my-fork/rosa-seaplane
```

> ⚠️ _Ensure the new branch is pushed to the remote before swapping — the environment is built from the remote ref._

## Tear Down

```bash
# Interactive — fzf picker for environment selection
make ephemeral-teardown

# Explicit
make ephemeral-teardown ID=6bd2d3d7
```

Teardown destroys using whatever is already on the ephemeral CI branch; it does not pull from your feature branch.

The RC and all MC destroy executions start before waiting, so cluster destruction runs concurrently. The command waits for every execution to succeed before deleting cluster pipelines/projects and shared bootstrap resources.

If destroy failed and you pushed a fix on your feature branch, resync the CI branch from that branch and then destroy (do not use `make ephemeral-resync` — that runs apply):

```bash
make ephemeral-teardown ID=6bd2d3d7 RESYNC=1
```

## Further Reading

- [Milestone 2 slides](presentations/milestone-2/slides.md) -- ephemeral provider architecture and how environments are provisioned/torn down
- [ci/ephemeral-provider/README.md](../ci/ephemeral-provider/README.md) -- ephemeral provider internals
- [SRE UI Access — Integration](sop/sre-ui-access.md) -- accessing Grafana, ArgoCD, Prometheus, Thanos, and Loki in the integration environment
