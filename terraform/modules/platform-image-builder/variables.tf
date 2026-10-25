variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "region" {
  type        = string
  description = "AWS Region for the platform image builder"
  default     = "us-east-1"
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "name_prefix" {
  type        = string
  description = "Optional prefix for resource names (e.g., CI run hash for parallel e2e runs)"
  default     = ""
  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, digits, and hyphens."
  }
}

variable "platform_ecr_repo" {
  type        = string
  description = "Public ECR repository URI for the platform image"
}

variable "platform_ecr_repo_arn" {
  type        = string
  description = "Public ECR repository ARN for the platform image"
}
