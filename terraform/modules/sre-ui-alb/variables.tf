# =============================================================================
# SRE UI ALB Module Variables
# =============================================================================

# =============================================================================
# Required
# =============================================================================

variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID where the ALB will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for internal ALB placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for internet-facing ALB placement"
  type        = list(string)
  default     = []
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID. For EKS Auto Mode, use cluster_primary_security_group_id."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — required for eks:eks-cluster-name tag (EKS Auto Mode IAM)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used for internal ALB ingress rule"
  type        = string
}

# =============================================================================
# DNS / TLS (optional — resources skipped when environment_domain is empty)
# =============================================================================

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional zone (e.g. us-east-1.int0.rosa.devshift.org). When null, ACM cert and DNS records are not created."
  type        = string
  default     = null
}

variable "deployment_name" {
  description = "Logical deployment identifier used to compose SRE hostnames (e.g. us-east-1 or us-east-1-xg4y)"
  type        = string
}

variable "environment_domain" {
  description = "Base domain for the environment (e.g. int0.rosa.devshift.org). When null or empty, ACM cert and Route53 records are skipped."
  type        = string
  default     = null
}

# =============================================================================
# Access log retention (FedRAMP AU-11)
# =============================================================================

variable "access_logs_standard_days" {
  description = "Days to keep access logs in S3 Standard before transitioning to Glacier. FedRAMP Moderate floor is 90 days."
  type        = number
  default     = 90
}

variable "access_logs_glacier_days" {
  description = "Days after which access logs in Glacier are permanently deleted. Total retention = standard_days + this value."
  type        = number
  default     = 275 # 90 standard + 275 glacier = 365 days total
}

# =============================================================================
# ALB behaviour
# =============================================================================

variable "internal" {
  description = "When true (default), ALB is internal — only reachable from within the VPC. Set to false for internet-facing."
  type        = bool
  default     = true
}

variable "allowed_source_cidrs" {
  description = "When ALB is internet-facing, security group allows HTTPS only from these CIDRs. Required when internal = false."
  type        = list(string)
  default     = []
}

# =============================================================================
# OIDC authentication (optional)
# =============================================================================

variable "oidc_enabled" {
  description = "When true, listener rules prepend an authenticate-oidc action before forwarding to the target group."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "OIDC issuer base URL (e.g. https://auth.redhat.com/auth/realms/EmployeeIDP). The authorization, token, and userinfo endpoints are derived from this using standard OIDC paths."
  type        = string
  default     = "https://auth.redhat.com/auth/realms/EmployeeIDP"
}

variable "oidc_clients" {
  description = "Per-service OIDC client credentials. Map key must match a service name in local.services (grafana, argocd, prometheus, thanos). Required when oidc_enabled = true."
  type = map(object({
    client_id     = string
    client_secret = string
  }))
  default   = {}
  sensitive = true
}
