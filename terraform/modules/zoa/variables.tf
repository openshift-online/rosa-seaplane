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

# --- Lambda image is mirrored from Quay into this regional ECR repository. ---

variable "zoa_lambda_source_image" {
  description = "Quay source image for ZOA Lambda (mirrored into regional ECR at apply time)."
  type        = string
  default     = "quay.io/redhat-user-workloads/rosa-tenant/rosa-seaplane-zoa-lambda"
}

variable "zoa_runner_source_image" {
  description = "Source image for ZOA Runner; K8s pulls directly from the source registry."
  type        = string
  default     = "quay.io/redhat-user-workloads/rosa-tenant/rosa-seaplane-zoa-runner"
}

variable "zoa_lambda_image_tag" {
  description = "Immutable Lambda image tag used for Quay-to-ECR mirroring."
  type        = string
  default     = "67ef089"

  validation {
    condition     = var.zoa_lambda_image_tag != ""
    error_message = "zoa_lambda_image_tag must be set; Seaplane always deploys the full ZOA stack."
  }
}

variable "zoa_runner_image_tag" {
  description = "Immutable ZOA Runner image tag."
  type        = string
  default     = "67ef089"
}
