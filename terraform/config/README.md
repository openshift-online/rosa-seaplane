# Terraform Configurations

## CI/CD Pipelines

For the current per-cluster pipeline architecture and lifecycle, see [CodePipeline Cluster Lifecycle](../../docs/design/codepipeline-cluster-lifecycle.md).

### `central-account-bootstrap/`

Creates the shared CodeStar connection, artifact bucket, CodePipeline role, CodeBuild roles, platform-image project, and platform-image ECR repository. The connection must be authorized manually in the AWS Console.

### `../modules/platform-image-builder/`

Defines the retained platform-image CodeBuild project. `scripts/provision-cluster-resources.sh` dynamically creates one CodePipeline and one CodeBuild project per RC or MC.

### `codebuild-regional-cluster/` and `codebuild-management-cluster/`

Contain the combined per-cluster buildspecs. Cluster pipeline and CodeBuild definitions are reconciled through AWS APIs; cluster infrastructure remains Terraform-managed.

## Cluster Infrastructure

### `regional-cluster/`

Provisions the full regional cluster stack: EKS, VPC, API Gateway, kube-applier DynamoDB tables, RDS (seaplane-db), authorization (DynamoDB + Pod Identity), ECS bootstrap, optional CloudTrail audit logging (disabled by default; enable with `enable_cloudtrail` for compliance environments), and optional bastion.

### `management-cluster/`

Provisions a management cluster: private EKS (1–2 nodes), ECS bootstrap, kube-applier IAM, and optional bastion. Hosts customer control planes.
