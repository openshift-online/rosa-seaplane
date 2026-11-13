output "role_arn" {
  description = "ARN of the IAM role for ecr-creds-sync Pod Identity."
  value       = aws_iam_role.ecr_creds_sync.arn
}
