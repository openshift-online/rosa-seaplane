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

# ECR outputs used by the RC and its Management Clusters.
output "lambda_ecr_url" {
  description = "Regional ECR repository URL for the Lambda image."
  value       = replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")
}

output "lambda_image_uri" {
  description = "Full regional ECR Lambda image URI; depends on Quay mirroring completing."
  value       = "${replace(aws_ecr_repository.lambda.repository_url, "ecr-fips", "ecr")}:${var.zoa_lambda_image_tag}"
  depends_on  = [null_resource.mirror_lambda]
}

output "runner_image_uri" {
  description = "Runner source image URI; K8s pulls directly from the source registry."
  value       = "${var.zoa_runner_source_image}:${var.zoa_runner_image_tag}"
}

output "sessions_table_name" {
  description = "DynamoDB table name for ZOA boundary sessions"
  value       = aws_dynamodb_table.boundary_sessions.name
}

# Target registration uses SSM Parameter Store, not DynamoDB.
# Each cluster's Terraform writes /zoa/targets/<deployment>/<cluster>.
# No table output needed — Access Lambda reads SSM with ambient creds.
