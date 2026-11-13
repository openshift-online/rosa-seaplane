# =============================================================================
# Management Cluster Infrastructure Variables
# =============================================================================

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Platform container image URI (used by bastion and ECS bootstrap)"
  type        = string
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

# =============================================================================
# Bastion Configuration Variables
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}

variable "enable_ecr_creds_sync" {
  description = "Enable the ecr-creds-sync Pod Identity role and association. Required when zero-egress ECR mirroring is active so the controller can call ecr:GetAuthorizationToken."
  type        = bool
  default     = false
}

# =============================================================================
# Management Cluster Configuration Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier for resource naming (e.g., 'mc01' or 'xg4y-mc01' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "regional_aws_account_id" {
  description = "AWS account ID where the regional cluster and IoT Core are hosted"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.regional_aws_account_id))
    error_message = "regional_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "dns_zone_operator_role_arn" {
  description = "ARN of the RC-side dns-zone-operator IAM role. When set, creates Pod Identity for external-dns and cert-manager."
  type        = string
  default     = ""
}

variable "zoa_outputs_bucket_arn" {
  description = "ARN of the ZOA outputs S3 bucket in the regional account (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "zoa_kms_key_arn" {
  description = "ARN of the ZOA KMS key in the regional account for S3 SSE-KMS (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "rhobs_api_url" {
  description = "API Gateway URL for Prometheus remote_write (read from RC terraform state)"
  type        = string
  default     = ""
}

# =============================================================================
# ZOA Lambda Configuration (per-VPC deployment for direct EKS access)
# =============================================================================

variable "zoa_lambda_ecr_url" {
  description = "ECR repository URL for ZOA Lambda (RC output, cross-account pull via OU policy)"
  type        = string

  validation {
    condition     = var.zoa_lambda_ecr_url != ""
    error_message = "zoa_lambda_ecr_url must be set from regional cluster outputs; Seaplane always deploys the full ZOA stack on MC."
  }
}

variable "zoa_lambda_image_tag" {
  description = "Immutable tag for the ZOA Lambda image (used with ECR URL from RC output)."
  type        = string
  default     = "67ef089"
}

variable "zoa_runner_image_tag" {
  description = "Immutable tag for the ZOA Runner image. Defaults to same build as Lambda."
  type        = string
  default     = "67ef089"
}

variable "zoa_runner_source_image" {
  description = "Source registry image for ZOA Runner (K8s pulls directly, no ECR mirror)"
  type        = string
  default     = "quay.io/rrp-dev-ci/zoa-runner"
}

variable "worker_node_ami_id" {
  description = "Custom AMI ID for the Karpenter bootstrap managed node group. Empty (default) uses the EKS-optimized AL2023 AMI. When set, the node group switches to a CUSTOM AMI and the launch template supplies nodeadm bootstrap user_data (assumes a nodeadm-compatible image, e.g. RHEL/AL2023)."
  type        = string
  default     = ""
}

variable "worker_node_root_volume_size" {
  description = "Root EBS volume size (GiB) for the Karpenter bootstrap nodes."
  type        = number
  default     = 50
}

variable "zoa_table_name" {
  description = "DynamoDB executions table name (in RC account)"
  type        = string
  default     = ""
}

variable "zoa_audit_table_name" {
  description = "DynamoDB audit table name (in RC account)"
  type        = string
  default     = ""
}

variable "zoa_uploader_role_arn" {
  description = "ARN of the ZOA uploader role (in RC account, for STS AssumeRole)"
  type        = string
  default     = ""
}

variable "zoa_data_access_role_arn" {
  description = "ARN of the ZOA data-access role (in RC account, for cross-account DynamoDB+S3)"
  type        = string
  default     = ""
}

variable "zoa_boundary_image" {
  description = "Full container image reference for ZOA Boundary ECS tasks (source:tag, set by buildspec from deploy config)."
  type        = string

  validation {
    condition     = var.zoa_boundary_image != ""
    error_message = "zoa_boundary_image must be set; Seaplane always deploys the full ZOA stack."
  }
}

variable "zoa_boundary_session_idle_timeout_seconds" {
  description = "Boundary session terminal idle timeout (seconds) for this MC worker reaper. Must match RC zoa_boundary_session_idle_timeout_seconds (same deploy config key)."
  type        = number
  default     = 3600

  validation {
    condition     = var.zoa_boundary_session_idle_timeout_seconds >= 60 && var.zoa_boundary_session_idle_timeout_seconds <= 86400
    error_message = "zoa_boundary_session_idle_timeout_seconds must be between 60 and 86400."
  }
}

variable "zoa_boundary_session_stale_creating_seconds" {
  description = "Max time (seconds) a session may stay in creating before the MC worker reaper cleans it up. Must match RC deploy config (SESSION_STALE_CREATING_SECONDS)."
  type        = number
  default     = 900

  validation {
    condition     = var.zoa_boundary_session_stale_creating_seconds >= 60 && var.zoa_boundary_session_stale_creating_seconds <= 86400
    error_message = "zoa_boundary_session_stale_creating_seconds must be between 60 and 86400."
  }
}

variable "zoa_lambda_api_concurrency" {
  description = "Reserved concurrency for ZOA API Lambda on MC (-1 = unreserved). Same deploy key as RC (regional_cluster in config hierarchy); see config/defaults.yaml."
  type        = number

  validation {
    condition     = var.zoa_lambda_api_concurrency == -1 || var.zoa_lambda_api_concurrency >= 1
    error_message = "zoa_lambda_api_concurrency must be -1 (unreserved) or >= 1; 0 disables the Lambda."
  }
}

variable "zoa_lambda_worker_concurrency" {
  description = "Reserved concurrency for ZOA Worker Lambda on MC (-1 = unreserved). Same deploy key as RC (regional_cluster in config hierarchy); see config/defaults.yaml."
  type        = number

  validation {
    condition     = var.zoa_lambda_worker_concurrency == -1 || var.zoa_lambda_worker_concurrency >= 1
    error_message = "zoa_lambda_worker_concurrency must be -1 (unreserved) or >= 1; 0 disables the Lambda."
  }
}

variable "zoa_sessions_table_name" {
  description = "DynamoDB table name for ZOA boundary sessions (in RC account, read from RC state)."
  type        = string
  default     = ""
}

variable "zoa_deployment_name" {
  description = "ZOA logical deployment name (same as RC deployment_name). Boundary ECS env; MC SSM registration uses deploy JSON in provision-mc-zoa-target-ssm.sh."
  type        = string
  default     = ""
}

variable "zoa_access_lambda_role_arn" {
  description = "ARN of the RC ZOA Access Lambda execution role (from regional cluster outputs). Required for MC boundary cross-account IAM trust."
  type        = string
  default     = ""

  validation {
    condition     = var.zoa_access_lambda_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.zoa_access_lambda_role_arn))
    error_message = "zoa_access_lambda_role_arn must be empty or a valid IAM role ARN."
  }
}

variable "oidc_bucket_name" {
  description = "S3 bucket name for regional OIDC discovery documents (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_bucket_arn" {
  description = "S3 bucket ARN for regional OIDC discovery documents (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_bucket_region" {
  description = "AWS region of the regional OIDC S3 bucket (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "oidc_writer_role_arn" {
  description = "ARN of the RC-side oidc-writer IAM role (MC operators assume this for OIDC S3+KMS access)"
  type        = string
  default     = ""
}

variable "oidc_key_reader_role_arn" {
  description = "ARN of the RC-side oidc-key-reader IAM role (MC ESO assumes this to read OIDC signing keys from Secrets Manager)"
  type        = string
  default     = ""
}

variable "oidc_cloudfront_domain" {
  description = "CloudFront domain for the regional OIDC issuer URL (read from RC terraform state)"
  type        = string
  default     = ""
}

variable "eph_prefix" {
  description = "Ephemeral environment prefix (e.g., eph-a1b2c3). When set, added as an ephemeral-prefix tag for cost analysis of ephemeral environments."
  type        = string
  default     = ""
}

