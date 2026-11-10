variable "regional_id" {
  description = "Regional identifier prefix for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment name (e.g. 'ephemeral', 'integration', 'production'). Controls S3 force_destroy behavior."
  type        = string
}

variable "dynamodb_deletion_protection" {
  description = "Enable deletion protection for ZOA DynamoDB tables"
  type        = bool
  default     = true
}

variable "billing_mode" {
  description = "DynamoDB billing mode"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "mc_ou_path" {
  description = "AWS Organizations OU path for Management Cluster accounts (used in cross-account S3/KMS policies)"
  type        = string

  validation {
    condition     = length(var.mc_ou_path) > 10 && startswith(var.mc_ou_path, "o-")
    error_message = "mc_ou_path must be a valid AWS Organizations path starting with 'o-' (e.g., 'o-abc123/r-root/ou-xxxx-yyyy/')"
  }
}

variable "output_retention_days" {
  description = "Days to retain TA outputs in S3"
  type        = number
  default     = 365
}

# --- Lambda image (mirrored from source registry → ECR in this module) ---
# Runner and boundary images are referenced by tag from the source registry in zoa-lambda / deploy config.

variable "zoa_lambda_source_image" {
  description = "Source registry image for ZOA Lambda (mirrored to ECR at deploy time)"
  type        = string
  default     = "quay.io/rrp-dev-ci/zoa-lambda"
}

variable "zoa_runner_source_image" {
  description = "Source registry image for ZOA Runner (K8s pulls directly, no ECR mirror)"
  type        = string
  default     = "quay.io/rrp-dev-ci/zoa-runner"
}

variable "zoa_lambda_image_tag" {
  description = "Immutable image tag for the ZOA Lambda. Used for source→ECR mirroring."
  type        = string
  default     = "67ef089"

  validation {
    condition     = var.zoa_lambda_image_tag != ""
    error_message = "zoa_lambda_image_tag must be set; Seaplane always deploys the full ZOA stack."
  }
}

variable "zoa_runner_image_tag" {
  description = "Immutable image tag for the ZOA Runner (K8s Job)."
  type        = string
  default     = "67ef089"
}
