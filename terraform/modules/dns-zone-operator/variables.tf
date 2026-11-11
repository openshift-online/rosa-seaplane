# =============================================================================
# DNS Zone Operator Module Variables
# =============================================================================

variable "tags" {
  description = "Base tags to merge with module-specific tags (function, module)"
  type        = map(string)
  default     = {}
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "zone_shard_hosted_zone_ids" {
  description = "Route53 hosted zone IDs for zone shards that operators can manage"
  type        = list(string)
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary ARN applied to the dns-zone-operator role. The dns-provisioner requires this boundary on CreateRole."
  type        = string
  default     = null
}

variable "region_ou_path" {
  description = "AWS Organizations OU path for MC accounts (e.g. o-abc123/r-abc1/ou-abc1-abc12345/). The module appends /* for the IAM trust policy wildcard."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]+/r-[a-z0-9]+/ou-[a-z0-9]+-[a-z0-9]+(/ou-[a-z0-9]+-[a-z0-9]+)*/", var.region_ou_path))
    error_message = "region_ou_path must be a valid AWS Organizations OU path ending with /: o-xxx/r-xxx/ou-xxx-xxx/"
  }
}
