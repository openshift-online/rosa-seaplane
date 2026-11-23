output "table_name" {
  description = "DynamoDB table name for ZOA executions"
  value       = aws_dynamodb_table.executions.name
}

output "audit_table_name" {
  description = "DynamoDB table name for ZOA audit log"
  value       = aws_dynamodb_table.audit_log.name
}

output "bucket_name" {
  description = "S3 bucket name for ZOA outputs"
  value       = aws_s3_bucket.outputs.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for ZOA outputs"
  value       = aws_s3_bucket.outputs.arn
}

output "kms_key_arn" {
  description = "KMS key ARN for ZOA encryption"
  value       = aws_kms_key.zoa.arn
}

# Lambda outputs

output "uploader_role_arn" {
  description = "ARN of the uploader IAM role (Lambda assumes this for scoped S3 creds)"
  value       = aws_iam_role.uploader.arn
}

output "data_access_role_arn" {
  description = "ARN of the data-access role (MC Lambdas assume this for cross-account DynamoDB+S3)"
  value       = aws_iam_role.data_access.arn
}

# ECR

output "lambda_ecr_url" {
  description = "ECR repository URL for zoa-lambda image (normalized to non-FIPS endpoint)"
  value       = replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")
}

output "lambda_image_uri" {
  description = "Full ECR image URI for Lambda (repo:tag). Normalized to non-FIPS endpoint for Lambda API compatibility."
  value       = "${replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")}:${var.zoa_lambda_image_tag}"

  # Ensure the image has been mirrored to ECR before any consumer uses this URI.
  # Without this, Terraform resolves the URI as soon as the ECR repository exists
  # (from repository_url), allowing downstream aws_lambda_function resources to
  # start creating before the skopeo mirror has finished pushing the image.
  depends_on = [null_resource.mirror_lambda]
}

output "runner_image_uri" {
  description = "Source image URI for the K8s Job runner. K8s nodes pull directly from source registry."
  value       = "${var.zoa_runner_source_image}:${var.zoa_runner_image_tag}"
}

output "sessions_table_name" {
  description = "DynamoDB table name for ZOA boundary sessions"
  value       = aws_dynamodb_table.boundary_sessions.name
}

# Target registration uses SSM Parameter Store, not DynamoDB.
# Each cluster's Terraform writes /zoa/targets/<deployment>/<cluster>.
# No table output needed — Access Lambda reads SSM with ambient creds.

