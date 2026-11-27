variable "table_names" {
  type = object({
    policies = string
    global   = string
    regional = string
  })
  description = "Explicit table names for policies, global attachments, and regional attachments."
  validation {
    condition = length(distinct(values(var.table_names))) == 3 && alltrue([
      for name in values(var.table_names) : can(regex("^[A-Za-z0-9_.-]{3,255}$", name))
    ])
    error_message = "Supply three distinct valid DynamoDB table names."
  }
}

variable "enable_retention" {
  type        = bool
  description = "Protect tables from deletion and janitor cleanup, with PITR. Disable for environments whose tables die with them."
}
