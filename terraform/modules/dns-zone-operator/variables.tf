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

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional (parent) zone. Grants read access so external-dns can discover zone shards. Set to null when the role lives in a separate DNS shard account (the regional zone is then in a different account and cannot be listed cross-account; external-dns relies on ListHostedZones on * for discovery)."
  type        = string
  default     = null
}

variable "zone_shard_hosted_zone_ids" {
  description = "Route53 hosted zone IDs for zone shards that operators can manage"
  type        = list(string)
}

variable "region_ou_path" {
  description = "AWS Organizations OU path for MC accounts (e.g. o-abc123/r-abc1/ou-abc1-abc12345/). The module appends /* for the IAM trust policy wildcard."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]+/r-[a-z0-9]+/ou-[a-z0-9]+-[a-z0-9]+(/ou-[a-z0-9]+-[a-z0-9]+)*/", var.region_ou_path))
    error_message = "region_ou_path must be a valid AWS Organizations OU path ending with /: o-xxx/r-xxx/ou-xxx-xxx/"
  }
}
