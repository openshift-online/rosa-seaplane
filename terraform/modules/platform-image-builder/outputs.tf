# =============================================================================
# Platform Image Builder Outputs
# =============================================================================

output "build_platform_image_project_name" {
  description = "Name of the build-platform-image CodeBuild project"
  value       = aws_codebuild_project.build_platform_image.name
}

output "github_connection_arn" {
  description = "ARN of the shared GitHub connection"
  value       = data.aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Status of the shared GitHub connection (requires manual authorization)"
  value       = data.aws_codestarconnections_connection.github.connection_status
}

# =============================================================================
# General Information
# =============================================================================

output "central_account_id" {
  description = "AWS Account ID where the platform image builder is deployed"
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS Region where the platform image builder is deployed"
  value       = var.region
}
