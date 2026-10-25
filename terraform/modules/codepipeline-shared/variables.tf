variable "name_prefix" {
  type        = string
  description = "Optional prefix used for ephemeral resources."
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region containing the pipelines and artifact bucket."
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection."
}

variable "cluster_project_names" {
  type        = set(string)
  description = "Exact rendered RC/MC project names authorized before their scope tags are reconciled. Dynamic projects require the scope tag."
  default     = []
  validation {
    condition = alltrue([
      for name in var.cluster_project_names : can(regex("^[a-z0-9][a-z0-9-]*$", name))
    ])
    error_message = "cluster_project_names must contain exact lowercase cluster names without wildcards."
  }
}
