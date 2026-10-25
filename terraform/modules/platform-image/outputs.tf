output "container_image" {
  description = "Full container image reference (repository:tag)"
  value       = local.container_image
}

output "ecr_repository_url" {
  description = "Public ECR repository URL"
  value       = aws_ecrpublic_repository.platform.repository_uri
}

output "ecr_repository_arn" {
  description = "Public ECR repository ARN"
  value       = aws_ecrpublic_repository.platform.arn
}

output "image_tag" {
  description = "Current image tag derived from Dockerfile SHA"
  value       = local.dockerfile_hash
}
