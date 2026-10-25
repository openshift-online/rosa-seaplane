variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (e.g., '/rosa-regional/slack/webhook-url')"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names (e.g., 'abc123-' or empty string)"
  default     = ""
}

variable "project_names" {
  type        = list(string)
  description = "List of CodeBuild project names to monitor for failures. Only failures from these projects will trigger notifications."
}

