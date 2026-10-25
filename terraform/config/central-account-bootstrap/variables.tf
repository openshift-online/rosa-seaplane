# =============================================================================
# GitHub Repository Configuration
# =============================================================================

variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "name_prefix" {
  type        = string
  description = "Optional prefix for resource names (e.g., CI run hash for parallel e2e runs)"
  default     = ""
}

variable "iam_role_prefix" {
  type        = string
  description = "Optional prefix for IAM role names. Defaults to name_prefix if not set. Ephemeral envs use eph-{id}, standing envs use empty string for unprefixed roles."
  default     = null
}

# =============================================================================
# AWS Configuration
# =============================================================================

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline Infrastructure"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment to monitor (e.g., integration, staging, production)"
  default     = "staging"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be a single path segment (lowercase letters, digits, hyphen)."
  }
}

variable "regional_cluster" {
  description = "Rendered RC project and resolved target account/administrator role. Null permits destruction from a fresh checkout without deployment inputs."
  type = object({
    project_name          = string
    account_id            = string
    child_admin_role_name = string
  })
  default = null
  validation {
    condition = var.regional_cluster == null ? true : (
      can(regex("^[a-z0-9][a-z0-9-]*$", var.regional_cluster.project_name)) &&
      can(regex("^[0-9]{12}$", var.regional_cluster.account_id)) &&
      can(regex("^[A-Za-z0-9_+=,.@-]+(/[A-Za-z0-9_+=,.@-]+)*$", var.regional_cluster.child_admin_role_name))
    )
    error_message = "regional_cluster must contain an exact cluster name, 12-digit account ID, and administrator role name/path without wildcards."
  }
}

variable "management_clusters" {
  description = "Rendered MC projects and resolved target accounts/administrator roles. Refresh bootstrap authorization before provisioning an MC in a new target account."
  type = list(object({
    project_name          = string
    account_id            = string
    child_admin_role_name = string
  }))
  default = []
  validation {
    condition = alltrue([
      for cluster in var.management_clusters :
      can(regex("^[a-z0-9][a-z0-9-]*$", cluster.project_name)) &&
      can(regex("^[0-9]{12}$", cluster.account_id)) &&
      can(regex("^[A-Za-z0-9_+=,.@-]+(/[A-Za-z0-9_+=,.@-]+)*$", cluster.child_admin_role_name))
    ])
    error_message = "management_clusters must contain exact cluster names, 12-digit account IDs, and administrator role names/paths without wildcards."
  }
}

# =============================================================================
# Notifications Configuration
# =============================================================================

variable "enable_slack_notifications" {
  type        = bool
  description = "Enable Slack notifications for CodeBuild failures. When true, slack_webhook_ssm_param must point to a valid SSM parameter."
  default     = false
}

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only used when enable_slack_notifications is true)"
  default     = "/rosa-regional/slack/webhook-url"
}

# =============================================================================
# ZOA Deployment Discovery
# =============================================================================

variable "zoa_central_deployments_primary_region" {
  type        = string
  description = "Central SSM region for primary /zoa/deployments/* (must match regional-cluster)."
  default     = "us-east-1"
}

variable "zoa_central_deployments_replica_region" {
  type        = string
  description = "Central SSM region for replica /zoa/deployments/* (must match regional-cluster)."
  default     = "eu-west-1"
}
