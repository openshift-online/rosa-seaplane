# =============================================================================
# Regional Cluster Infrastructure Variables
# =============================================================================

variable "regional_id" {
  description = "Deterministic regional cluster identifier for resource naming (e.g., 'regional' or 'xg4y-regional' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "deployment_name" {
  description = "Logical deployment identifier for DNS zone naming. Equals region for normal deployments; includes a suffix for CI/ephemeral (e.g. us-east-1-xg4y)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,23}[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be 1-25 characters, lowercase alphanumeric or '-', starting and ending with alphanumeric."
  }
}

variable "container_image" {
  description = "Platform container image URI (used by bastion and ECS bootstrap)"
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must be a non-empty ECR image URI"
  }
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "central_aws_profile" {
  description = "AWS CLI profile for central account credentials. Pipelines set this to \"central\" (buildspec writes profile from CodeBuild home creds). Required for cross-account central SSM and ZOA Access invoker trust account ID."
  type        = string
  default     = ""
}

variable "zoa_access_trusted_assumer_role_names" {
  description = <<-EOT
    Central Account IAM role names that may assume the ZOA Access invoker role in this RC.
    Use the full role name exactly as in IAM (e.g. OrganizationAccountAccessRole).
    Optional in config; may be empty if zoa_access_trusted_assumer_role_name_suffixes is set. RC apply
    requires at least one entry across both lists. Each role must already exist in the central account (IAM validates principals).
  EOT
  type        = list(string)
  default     = []
}

variable "zoa_access_trusted_assumer_role_name_suffixes" {
  description = <<-EOT
    App-interface access role name suffixes only (the role-1.yml name field), not the full IAM role name.
    App-interface provisions SAML hub roles in central as "<central_account_id>-<suffix>"; we avoid hardcoding
    the account ID in environment config by listing suffixes here and expanding to full role names at RC apply
    using data.aws_caller_identity.central. Optional in config; at least one name or suffix required at apply.
    Expanded roles must exist in the central account.
  EOT
  type        = list(string)
  default     = []
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

variable "enable_cloudtrail" {
  description = "Enable CloudTrail audit logging (FedRAMP AU-12). Disable for ephemeral/CI to avoid per-account trail limits."
  type        = bool
  default     = false
}

variable "enable_api_custom_domain" {
  description = "Enable API Gateway custom domain and ACM certificate. Adds ~20 minutes for DNS-validated certificate provisioning."
  type        = bool
  default     = false
}

variable "enable_sre_tools_gateway" {
  description = "Enable internal ALB for SRE UI tools (Grafana, ArgoCD, Prometheus, Thanos, Loki). Requires environment_domain to be set for DNS/TLS."
  type        = bool
  default     = false
}

variable "enable_sre_public_access" {
  description = "When true, the SRE UI ALB is internet-facing. Combine with sre_allowed_source_cidrs to restrict access."
  type        = bool
  default     = false
}

variable "enable_sre_oidc_auth" {
  description = "When true, ALB listener rules require OIDC authentication via Red Hat SSO. Requires per-service client IDs and secrets."
  type        = bool
  default     = false
}

variable "sre_oidc_issuer_url" {
  description = "OIDC issuer base URL for the SRE UI ALB. Defaults to Red Hat SSO EmployeeIDP."
  type        = string
  default     = "https://auth.redhat.com/auth/realms/EmployeeIDP"
}

variable "sre_allowed_source_cidrs" {
  description = "When SRE ALB is internet-facing, allow HTTPS only from these CIDRs (e.g. corporate proxy egress). Leave empty to allow all."
  type        = list(string)
  default     = []
}

variable "sre_grafana_oidc_client_id" {
  description = "OIDC client ID for Grafana. Required when enable_sre_oidc_auth = true."
  type        = string
  default     = ""
}

variable "sre_grafana_oidc_client_secret" {
  description = "OIDC client secret for Grafana. Supply via Secrets Manager — never commit to git."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sre_argocd_oidc_client_id" {
  description = "OIDC client ID for ArgoCD. Required when enable_sre_oidc_auth = true."
  type        = string
  default     = ""
}

variable "sre_argocd_oidc_client_secret" {
  description = "OIDC client secret for ArgoCD. Supply via Secrets Manager — never commit to git."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sre_prometheus_oidc_client_id" {
  description = "OIDC client ID for Prometheus. Required when enable_sre_oidc_auth = true."
  type        = string
  default     = ""
}

variable "sre_prometheus_oidc_client_secret" {
  description = "OIDC client secret for Prometheus. Supply via Secrets Manager — never commit to git."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sre_thanos_oidc_client_id" {
  description = "OIDC client ID for Thanos. Required when enable_sre_oidc_auth = true."
  type        = string
  default     = ""
}

variable "sre_thanos_oidc_client_secret" {
  description = "OIDC client secret for Thanos. Supply via Secrets Manager — never commit to git."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_sns_alerting" {
  description = "Enable SNS alerting for alert fan-out"
  type        = bool
  default     = false
}

variable "enable_rate_limit_redis" {
  description = "Enable ElastiCache Redis for Platform API rate limiting"
  type        = bool
  default     = true
}

variable "valkey_node_type" {
  description = "ElastiCache Valkey node type for rate limiting"
  type        = string
  default     = "cache.t4g.micro"
}

variable "valkey_engine_version" {
  description = "ElastiCache Valkey engine version"
  type        = string
  default     = "9.1"
}

# =============================================================================
# Seaplane DB Variables
# =============================================================================

variable "seaplane_db_instance_class" {
  description = "Aurora instance class for Seaplane DB"
  type        = string
  default     = "db.r6g.large"
}

variable "seaplane_db_engine_version" {
  description = "Aurora PostgreSQL engine version for Seaplane DB"
  type        = string
  default     = "16.13"
}

variable "seaplane_db_backup_retention_period" {
  description = "Days to retain automated backups (PITR window)"
  type        = number
  default     = 14
}

variable "seaplane_db_deletion_protection" {
  description = "Enable deletion protection for Seaplane DB Aurora"
  type        = bool
  default     = true
}

variable "zoa_dynamodb_deletion_protection" {
  description = "Enable deletion protection for ZOA DynamoDB tables"
  type        = bool
  default     = true
}

variable "seaplane_db_skip_final_snapshot" {
  description = "Skip final snapshot when destroying (ephemeral only)"
  type        = bool
  default     = false
}

variable "seaplane_db_performance_insights_enabled" {
  description = "Enable Performance Insights for Seaplane DB Aurora"
  type        = bool
  default     = true
}

variable "seaplane_db_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds for Seaplane DB Aurora (0 to disable)"
  type        = number
  default     = 60
}

# =============================================================================
# Platform API Variables
# =============================================================================

variable "zone_shard_count" {
  description = "Number of DNS zone shards to create under the regional zone. Each shard supports ~10k records."
  type        = number
  default     = 1

  validation {
    condition     = var.zone_shard_count >= 1 && var.zone_shard_count <= 100
    error_message = "zone_shard_count must be between 1 and 100 (each shard costs $0.50/month)"
  }
}


variable "environment_domain" {
  description = "Environment domain name (e.g. int0.rosa.devshift.net). When set, creates the regional DNS zone (<deployment_name>.<environment_domain>). When null, no DNS resources are created."
  type        = string
  default     = null
}

# =============================================================================
# API Gateway Method Settings Variables
# =============================================================================

variable "api_metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for all API methods"
  type        = bool
  default     = true
}

variable "api_logging_level" {
  description = "CloudWatch logging level for API methods (OFF, ERROR, INFO)"
  type        = string
  default     = "ERROR"
}

variable "api_data_trace_enabled" {
  description = "Enable full request/response data tracing in CloudWatch logs (avoid in production)"
  type        = bool
  default     = false
}

variable "api_throttling_burst_limit" {
  description = "Maximum concurrent requests allowed (burst) for API Gateway methods"
  type        = number
  default     = 500
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests per second allowed for API Gateway methods"
  type        = number
  default     = 100
}

# =============================================================================
# RHOBS API Gateway Variables
# =============================================================================

variable "rhobs_apigw_metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for RHOBS API Gateway methods"
  type        = bool
  default     = true
}

# =============================================================================
# Regional OIDC Configuration Variables
# =============================================================================

variable "mc_ou_path" {
  description = "AWS Organizations OU path for Management Cluster accounts (StringLike condition, supports wildcards, e.g. 'o-*/r-*/ou-*/*')"
  type        = string

  validation {
    condition     = var.mc_ou_path != ""
    error_message = "mc_ou_path must be set to an AWS Organizations OU path to enable cross-account OIDC writes from Management Cluster accounts."
  }
}

# =============================================================================
# Thanos Configuration Variables
# =============================================================================

variable "thanos_metrics_retention_days" {
  description = "Number of days to retain metrics in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 365
}

variable "thanos_namespace" {
  description = "Kubernetes namespace where Thanos is deployed"
  type        = string
  default     = "thanos"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.thanos_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "thanos_service_account" {
  description = "Kubernetes service account name for Thanos"
  type        = string
  default     = "thanos-operator"
}

# =============================================================================
# Loki Configuration Variables
# =============================================================================

variable "loki_logs_retention_days" {
  description = "Number of days to retain logs in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 90
}

variable "loki_namespace" {
  description = "Kubernetes namespace where Loki is deployed"
  type        = string
  default     = "loki"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.loki_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "loki_service_account" {
  description = "Kubernetes service account name for Loki (shared by all Loki components in Distributed mode)"
  type        = string
  default     = "loki"
}

# =============================================================================
# PagerDuty Configuration Variables
# =============================================================================

variable "enable_pagerduty" {
  description = "Enable PagerDuty service provisioning for this region"
  type        = bool
  default     = false
}

variable "pagerduty_escalation_policy_id" {
  description = "ID of an existing PagerDuty escalation policy to use for the regional service"
  type        = string
  default     = ""
}

variable "eph_prefix" {
  description = "Ephemeral environment prefix (e.g., xg4y). Passed to PagerDuty service naming to avoid collisions."
  type        = string
  default     = ""
}

# =============================================================================
# Cross-Account MC Identity
# =============================================================================

variable "management_clusters" {
  description = "Comma-separated colon-delimited MC entries (e.g. mc01:123456789012,mc02:987654321098)"
  type        = string
  default     = ""
}

# =============================================================================
# ZOA Lambda
# =============================================================================

variable "zoa_lambda_image_tag" {
  description = "Immutable tag for the ZOA Lambda image (Quay→ECR mirroring). Override with a CI-built tag to validate a zoa PR."
  type        = string
  default     = "67ef089"

  validation {
    condition     = var.zoa_lambda_image_tag != ""
    error_message = "zoa_lambda_image_tag must be set; Seaplane always deploys the full ZOA stack."
  }
}

variable "zoa_runner_image_tag" {
  description = "Immutable tag for the ZOA Runner image (K8s Job). Defaults to same build as Lambda but can be overridden independently."
  type        = string
  default     = "67ef089"
}

variable "zoa_lambda_source_image" {
  description = "Source registry image for ZOA Lambda (mirrored to ECR at deploy time). Override together with zoa_lambda_image_tag to point at a fork or CI registry."
  type        = string
  default     = "quay.io/rrp-dev-ci/zoa-lambda"
}

variable "zoa_runner_source_image" {
  description = "Source registry image for ZOA Runner (K8s pulls directly, no ECR mirror). Override together with zoa_runner_image_tag to point at a fork or CI registry."
  type        = string
  default     = "quay.io/rrp-dev-ci/zoa-runner"
}

# =============================================================================
# ZOA Boundary Variables
# =============================================================================

variable "zoa_boundary_image" {
  description = "Full container image reference for ZOA Boundary ECS tasks (source:tag, set by buildspec from deploy config)."
  type        = string

  validation {
    condition     = var.zoa_boundary_image != ""
    error_message = "zoa_boundary_image must be set; Seaplane always deploys the full ZOA stack."
  }
}

variable "zoa_boundary_session_idle_timeout_seconds" {
  description = "Boundary session terminal idle timeout (seconds). Passed to module.zoa_lambda (worker reaper) and module.zoa_access (RunTask ZOA_SESSION_IDLE_TIMEOUT_SECONDS). Must stay aligned with MC zoa_lambda for MC targets."
  type        = number
  default     = 3600

  validation {
    condition     = var.zoa_boundary_session_idle_timeout_seconds >= 60 && var.zoa_boundary_session_idle_timeout_seconds <= 86400
    error_message = "zoa_boundary_session_idle_timeout_seconds must be between 60 and 86400."
  }
}

variable "zoa_boundary_session_max_duration_hours" {
  description = "Default and maximum boundary session length (hours). Passed to module.zoa_access only (SESSION_MAX_DURATION_HOURS; deadline stored in Dynamo)."
  type        = number
  default     = 4

  validation {
    condition     = var.zoa_boundary_session_max_duration_hours >= 1 && var.zoa_boundary_session_max_duration_hours <= 24
    error_message = "zoa_boundary_session_max_duration_hours must be between 1 and 24."
  }
}

variable "zoa_boundary_session_stale_creating_seconds" {
  description = "Max time (seconds) a session may stay in creating before the worker reaper cleans it up. Passed to module.zoa_lambda only (SESSION_STALE_CREATING_SECONDS)."
  type        = number
  default     = 900

  validation {
    condition     = var.zoa_boundary_session_stale_creating_seconds >= 60 && var.zoa_boundary_session_stale_creating_seconds <= 86400
    error_message = "zoa_boundary_session_stale_creating_seconds must be between 60 and 86400."
  }
}

variable "zoa_lambda_api_concurrency" {
  description = "Reserved concurrency for ZOA API Lambda (-1 = unreserved). Authoritative values: config/defaults.yaml (regional_cluster); ephemeral override in config/ephemeral/defaults.yaml. Set at apply time via TF_VAR from rendered deploy JSON."
  type        = number

  validation {
    condition     = var.zoa_lambda_api_concurrency == -1 || var.zoa_lambda_api_concurrency >= 1
    error_message = "zoa_lambda_api_concurrency must be -1 (unreserved) or >= 1; 0 disables the Lambda."
  }
}

variable "zoa_lambda_worker_concurrency" {
  description = "Reserved concurrency for ZOA Worker Lambda (-1 = unreserved). Authoritative values: config/defaults.yaml (regional_cluster); ephemeral override in config/ephemeral/defaults.yaml."
  type        = number

  validation {
    condition     = var.zoa_lambda_worker_concurrency == -1 || var.zoa_lambda_worker_concurrency >= 1
    error_message = "zoa_lambda_worker_concurrency must be -1 (unreserved) or >= 1; 0 disables the Lambda."
  }
}

variable "zoa_lambda_access_concurrency" {
  description = "Reserved concurrency for ZOA Access Lambda (RC only; -1 = unreserved or >= 1 reserved). Authoritative values: config/defaults.yaml (regional_cluster); ephemeral override in config/ephemeral/defaults.yaml."
  type        = number

  validation {
    condition     = var.zoa_lambda_access_concurrency == -1 || var.zoa_lambda_access_concurrency >= 1
    error_message = "zoa_lambda_access_concurrency must be -1 (unreserved) or >= 1; 0 disables the Lambda."
  }
}

variable "zoa_central_deployments_primary_region" {
  description = "Central account SSM region for primary /zoa/deployments/* (must match rosa-seaplane-zoa accessclient.DefaultDeploymentsSSMRegion)."
  type        = string
  default     = "us-east-1"
}

variable "zoa_central_deployments_replica_region" {
  description = "Central account SSM region for replica /zoa/deployments/* (must match rosa-seaplane-zoa accessclient.ReplicaDeploymentsSSMRegion)."
  type        = string
  default     = "eu-west-1"
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

# =============================================================================
# OU Path (Backward-Compatible Read)
# =============================================================================

variable "region_ou_path" {
  description = "AWS Organizations OU path for the region. Resolved in buildspec with backward-compatible fallback (new nested path → legacy flat path) and passed via TF_VAR_region_ou_path."
  type        = string

  validation {
    condition     = var.region_ou_path != ""
    error_message = "region_ou_path must not be empty. Set via buildspec (scripts/buildspec/provision-infra-rc.sh) from SSM parameter /infra/<env>/<region>/ou-path or /infra/region-ou-path (legacy)."
  }
}
