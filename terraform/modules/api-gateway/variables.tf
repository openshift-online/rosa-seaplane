# =============================================================================
# Required Variables
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the ALB and VPC Link will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ALB and VPC Link placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "cloudwatch_role_name" {
  description = <<-EOT
    Name of the IAM role API Gateway assumes to deliver access logs. This module does not
    create it: AWS stores one logging role per account and region, shared by every REST API
    in the account, so it is provisioned once per AWS account and region outside this
    repository and read here only by an advisory diagnostic (evaluated on plan and apply). Nothing in this
    repository writes the account setting, so this value cannot turn logging on or off —
    changing it only changes which role name that diagnostic looks up. It is deliberately
    the same name in every account and must not contain regional_id.
  EOT
  type        = string
  default     = "rosa-seaplane-api-gateway-cloudwatch"

  validation {
    condition     = can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.cloudwatch_role_name))
    error_message = "cloudwatch_role_name must be a valid IAM role name (max 64 characters)."
  }
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - used to tag target groups with eks:eks-cluster-name"
  type        = string
}

# =============================================================================
# ALB and Target Group Configuration
# =============================================================================

variable "target_port" {
  description = "Port on which the backend service receives traffic"
  type        = number
  default     = 8000

  validation {
    condition     = var.target_port >= 1 && var.target_port <= 65535
    error_message = "Target port must be between 1 and 65535."
  }
}

variable "health_check_path" {
  description = "Path for ALB health checks on the backend service"
  type        = string
  default     = "/api/v0/live"
}

variable "health_check_interval" {
  description = "Interval in seconds between health checks"
  type        = number
  default     = 30

  validation {
    condition     = var.health_check_interval >= 5 && var.health_check_interval <= 300
    error_message = "Health check interval must be between 5 and 300 seconds."
  }
}

variable "health_check_timeout" {
  description = "Timeout in seconds for health check response"
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_timeout >= 2 && var.health_check_timeout <= 120
    error_message = "Health check timeout must be between 2 and 120 seconds."
  }
}

# =============================================================================
# API Gateway Configuration
# =============================================================================

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.stage_name))
    error_message = "Stage name can only contain alphanumeric characters, hyphens, and underscores."
  }
}


variable "api_description" {
  description = "Description for the API Gateway REST API"
  type        = string
  default     = "ROSA Seaplane API"
}

# =============================================================================
# Custom Domain Configuration (Optional)
# =============================================================================

variable "api_domain_name" {
  description = "Custom domain name for the API Gateway (e.g. api.us-east-1.int0.rosa.devshift.net). When null, no custom domain resources are created."
  type        = string
  default     = null

  validation {
    condition     = var.api_domain_name == null || can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.api_domain_name))
    error_message = "api_domain_name must be a valid domain name."
  }
}

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional delegation zone (e.g. the zone for us-east-1.int0.rosa.devshift.net) in the RC account. Used for ACM DNS validation and the API alias record. When null, ACM cert is created but DNS records must be managed externally."
  type        = string
  default     = null
}

# =============================================================================
# Method Settings Variables
# =============================================================================

variable "metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for all API methods"
  type        = bool
  default     = true
}

variable "logging_level" {
  description = "CloudWatch execution logging level for API methods (OFF, ERROR, INFO). INFO level logs full request/response headers which may include caller identity (PII consideration for customer-facing APIs)."
  type        = string
  default     = "ERROR"

  validation {
    condition     = contains(["OFF", "ERROR", "INFO"], var.logging_level)
    error_message = "logging_level must be one of: OFF, ERROR, INFO."
  }
}

variable "data_trace_enabled" {
  description = "Enable full request/response data tracing in CloudWatch logs (avoid in production — logs may contain sensitive data)"
  type        = bool
  default     = false
}

variable "throttling_burst_limit" {
  description = "Maximum concurrent requests allowed (burst). -1 inherits stage/account default."
  type        = number
  default     = 500
}

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed. -1 inherits stage/account default."
  type        = number
  default     = 100
}
