provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # When name_prefix is set (e.g., "eph-199b4083"), resource names become "eph-199b4083-build-platform-image", etc.
  name_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  # IAM role prefix is separately configurable. Defaults to name_prefix for backward compatibility.
  # Ephemeral: "eph-{id}-" → roles like "eph-199b4083-rc-codebuild-role"
  # Standing: "" → unprefixed roles like "rc-codebuild-role"
  # Can be overridden via iam_role_prefix variable (e.g., "int-" for integration)
  iam_role_prefix = var.iam_role_prefix != null ? (var.iam_role_prefix != "" ? "${var.iam_role_prefix}-" : "") : local.name_prefix

  regional_assume_role_arns = var.regional_cluster == null ? [] : [
    "arn:${data.aws_partition.current.partition}:iam::${var.regional_cluster.account_id}:role/${var.regional_cluster.child_admin_role_name}"
  ]
  # MC provisioning also reads state and updates discovery records in the RC account.
  management_assume_role_arns = distinct(concat(local.regional_assume_role_arns, [
    for cluster in var.management_clusters :
    "arn:${data.aws_partition.current.partition}:iam::${cluster.account_id}:role/${cluster.child_admin_role_name}"
  ]))
  regional_same_account = var.regional_cluster == null ? false : var.regional_cluster.account_id == data.aws_caller_identity.current.account_id
  management_same_account = local.regional_same_account || contains(
    [for cluster in var.management_clusters : cluster.account_id], data.aws_caller_identity.current.account_id
  )
  cluster_log_group_prefix = "/aws/codebuild/${basename(module.codepipeline_shared.pipeline_role_arn)}"
  regional_project_names   = var.regional_cluster == null ? [] : [var.regional_cluster.project_name]
  management_project_names = [for cluster in var.management_clusters : cluster.project_name]
  # Existing builds keep their original project log groups until the SDK
  # reconciles projects to the shared groups used by future cluster names.
  regional_log_groups = concat(["${local.cluster_log_group_prefix}/regional"], [
    for project in local.regional_project_names : "/aws/codebuild/${project}"
  ])
  management_log_groups = concat(["${local.cluster_log_group_prefix}/management"], [
    for project in local.management_project_names : "/aws/codebuild/${project}"
  ])
}

# Shared GitHub CodeStar Connection
# The bootstrap script ensures the shared connection exists and imports it here
# so Terraform can reference the selected ARN without deleting it on teardown.
# During teardown, `terraform state rm` removes it before destroy so the
# connection persists across CI runs.
resource "aws_codestarconnections_connection" "github" {
  name          = "rosa-regional-github-shared"
  provider_type = "GitHub"

  lifecycle {
    prevent_destroy = true
  }
}

# Platform Image ECR Repository
module "platform_image" {
  source = "../../modules/platform-image"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  resource_name_base = "rosa-regional"
  name_prefix        = var.name_prefix
  tags = {
    Name        = "rosa-seaplane-image"
    Environment = var.environment
  }
}

module "codepipeline_shared" {
  source = "../../modules/codepipeline-shared"

  github_connection_arn = aws_codestarconnections_connection.github.arn
  name_prefix           = var.name_prefix
  region                = var.region
  cluster_project_names = concat(local.regional_project_names, local.management_project_names)
}

module "platform_image_builder" {
  source = "../../modules/platform-image-builder"

  github_repository     = var.github_repository
  region                = var.region
  github_connection_arn = aws_codestarconnections_connection.github.arn
  platform_ecr_repo     = module.platform_image.ecr_repository_url
  platform_ecr_repo_arn = module.platform_image.ecr_repository_arn
  name_prefix           = var.name_prefix
}

# CodeBuild Failure Notifications
# Gated by an explicit feature flag (see var.enable_slack_notifications).
# Currently only monitors the build-platform-image project.
# RC/MC notifications are SDK-side (out of scope for this module).
module "codebuild_notifications" {
  source = "../../modules/codebuild-notifications"
  count  = var.enable_slack_notifications ? 1 : 0

  slack_webhook_ssm_param = var.slack_webhook_ssm_param
  name_prefix             = var.name_prefix
  project_names           = [module.platform_image_builder.build_platform_image_project_name]
}
