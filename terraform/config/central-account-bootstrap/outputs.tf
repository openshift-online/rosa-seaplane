# =============================================================================
# GitHub Connection
# =============================================================================

output "github_connection_arn" {
  description = "ARN of the shared GitHub connection (used by all CodeBuild projects)"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_name" {
  description = "Name of the shared GitHub connection"
  value       = aws_codestarconnections_connection.github.name
}

output "github_connection_status" {
  description = "Status of the shared GitHub connection (requires manual authorization if PENDING)"
  value       = aws_codestarconnections_connection.github.connection_status
}

# =============================================================================
# General Information
# =============================================================================

output "central_account_id" {
  description = "AWS Account ID where CodeBuild projects are deployed"
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS Region where CodeBuild projects are deployed"
  value       = var.region
}

# =============================================================================
# Platform Image
# =============================================================================

output "platform_ecr_repository_url" {
  description = "URL of the platform image ECR repository"
  value       = module.platform_image.ecr_repository_url
}

output "platform_image_tag" {
  description = "Tag of the platform image (based on Dockerfile hash)"
  value       = module.platform_image.image_tag
}

output "platform_container_image" {
  description = "Full container image URI (repository:tag) for use by provision-cluster-resources.sh"
  value       = module.platform_image.container_image
}

# =============================================================================
# Cluster CodeBuild Roles
# =============================================================================

output "rc_codebuild_role_arn" {
  description = "ARN of the centrally-managed IAM role used by RC CodeBuild projects"
  value       = aws_iam_role.rc_codebuild_role.arn
}

output "mc_codebuild_role_arn" {
  description = "ARN of the shared IAM role used by all MC CodeBuild projects"
  value       = aws_iam_role.mc_codebuild_role.arn
}

output "codepipeline_artifact_bucket_name" {
  description = "S3 bucket used by the dynamically managed RC/MC CodePipelines"
  value       = module.codepipeline_shared.artifact_bucket_name
}

output "codepipeline_role_arn" {
  description = "IAM role used by the dynamically managed RC/MC CodePipelines"
  value       = module.codepipeline_shared.pipeline_role_arn
}
