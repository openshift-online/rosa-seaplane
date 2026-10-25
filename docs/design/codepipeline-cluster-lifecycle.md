# CodePipeline Cluster Lifecycle

**Status:** Current

Each RC and MC has one CodePipeline invoking a single combined CodeBuild project.
Terraform owns shared resources; the cluster resource script owns dynamic
CodeBuild/CodePipeline lifecycle. The platform-image CodeBuild remains on-demand
with no webhook or dedicated pipeline.

## Lifecycle contract

`scripts/provision-cluster-resources.sh` supports:

- `create-rc`, `delete-rc`
- `create-mc`, `delete-mc`

Each action accepts one rendered cluster config from `pipeline-provisioner-inputs/`;
create actions also take `--region-deployment`. The no-argument form applies
the same operations to all rendered clusters for int/stage and ephemeral
bootstrap. Creating a CodePipeline starts one execution automatically; the
cluster resource script does not call `StartPipelineExecution`. Pipeline
resources are not Terraform state, allowing an MC autoscaler to manage them
without Terraform applies or per-MC pipeline state files.

Bootstrap creates the shared Terraform resources, ensures the platform image
exists, and invokes this script directly. Rerun it through bootstrap when the
cluster set or project/pipeline definitions change; existing pipeline push
filters only trigger infrastructure executions. A project is named after its
rendered `regional_id` or `management_id`, with `-pipeline` appended for the
associated CodePipeline.

## Authorization and ownership

Bootstrap reads the rendered cluster descriptors, resolves SSM account IDs,
and grants access to their exact target-account administrator roles. RC workers
can assume the Regional account role. MC workers can assume the configured
Management account roles and the Regional account role required for state,
registration, and cleanup. New target accounts or administrator roles require
a bootstrap rerun; creating another MC in an already authorized account does
not require adding its project name to IAM.

Each cluster CodeBuild project carries
`ProvisioningScope=<CodePipeline-role-ARN>`. That pipeline role can start, stop,
and inspect builds for the exact configured projects, or dynamic projects
carrying its scope. The lifecycle script
refuses to adopt a project tagged with another scope. This supports custom
`cluster_naming` patterns and dynamic MC names. Worker log groups use
`/aws/codebuild/<pipeline-role-name>/<regional|management>`, independent of the
project name. The exact configured projects' default log groups remain
authorized so running builds can finish while project definitions are updated.

These controls preserve the current bootstrap structure. They do not establish
separate account and environment ownership: deployments that share a pipeline
role also share its project scope, and same-account provisioning retains the
infrastructure permissions needed by upstream. The shared GitHub connection
has Terraform destruction protection and survives ephemeral teardown. The
provider must successfully detach it from that run's bootstrap state before
destroying the remaining bootstrap resources.

## Execution

Pipelines use a CodeStar connection, branch/file push filters, and V2
`SUPERSEDED` execution mode. Ephemeral push triggers stay enabled. The provider
adopts the execution for the pushed source revision when a pipeline's filters
match, and does not independently start that same revision. On initial
provision it adopts each automatic `CreatePipeline` execution. A resume without
a branch push reuses an active execution at the same SHA or explicitly starts a
retry if the pipeline is idle. Resyncs adopt push-triggered pipelines matched
by changed paths. An unmatched pipeline reuses its previous successful
execution, or is explicitly started if it has no successful execution yet. The
CodeBuild action uses the existing buildspec, service role, and Terraform
state. Ephemeral teardown pins its requested commit and passes `IS_DESTROY=true`
as a pipeline variable. The provider starts the RC and all MC destroy executions
before waiting, so cluster destruction runs concurrently. Full teardown waits
for every execution to succeed before deleting cluster pipelines/projects and
shared bootstrap resources, then deletes the ephemeral branch. A failed
execution or cleanup step stops subsequent cleanup. Teardown first disables
push triggers and drains active executions; failure to establish that condition
prevents destroy executions from starting. Fire-and-forget teardown exits after
starting all destroy executions, without waiting for cluster destruction or
deleting those pipeline/bootstrap resources or the branch.

The ephemeral provider starts or adopts and polls pipelines, validates the underlying
CodeBuild `APPLIED=true` and `APPLIED_SHA` contract, collects CodeBuild logs,
and invokes the same per-cluster delete actions during teardown.

## Migration from Terraform-managed pipelines

The previous upstream architecture owns RC/MC pipelines, their stage-specific
CodeBuild projects, and associated roles/buckets in Terraform, with a separate
central pipeline-provisioner. The per-cluster resource script does not migrate
these resources or their state. Running bootstrap is therefore not an automatic
in-place upgrade for an existing environment.

For a disposable ephemeral environment, complete teardown with the revision
that provisioned it before creating a new environment from this architecture.
For a standing environment, prepare and review a migration plan against its
actual state before applying the new central bootstrap:

1. Pause legacy source triggers and wait for active pipeline/build executions
   to finish. Inventory the central bootstrap state and each legacy RC/MC
   pipeline state, and save state backups and resource definitions.
2. Map shared resources that must survive (connection, platform-image builder,
   ECR repository, and shared IAM resources) to their new Terraform addresses.
   The central bootstrap includes `moved.tf` mappings for the retained builder,
   notification module, and shared MC role. Review these mappings, any additional
   moves/imports needed by the actual environment, and the resulting plan before
   applying.
3. Identify legacy per-cluster pipeline resources separately from target-account
   cluster infrastructure. Retire legacy pipeline resources with their original
   configuration and a reviewed plan, or explicitly transfer ownership of any
   reused resource. Removing a resource from state only stops Terraform tracking
   it; it does not delete a legacy pipeline or disable its trigger. Do not leave
   legacy and new pipelines able to apply to the same cluster concurrently.
4. Preserve the target-account infrastructure state buckets, keys, and cluster
   IDs. Create the new per-cluster resources only after the legacy execution
   path is inactive, then verify that the first execution uses the existing
   infrastructure state and completes successfully.

Environments that separately trialed standalone CodeBuild webhooks also need
those webhook triggers removed before enabling the new CodePipeline triggers.
There is no bundled webhook-cleanup or legacy-state migration script.
