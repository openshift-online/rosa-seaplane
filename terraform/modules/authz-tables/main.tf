# Authz storage tables. One schema for retained (separate state) and
# disposable (owned by an ephemeral RC) environments. prevent_destroy cannot be
# conditional, so retained tables rely on AWS deletion protection instead.
resource "aws_dynamodb_table" "authz" {
  for_each = var.table_names

  name                        = each.value
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.enable_retention

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = var.enable_retention
  }

  tags = merge({
    Name      = each.value
    Component = "platform-api-authz"
    ManagedBy = "terraform"
    function  = "authorization"
    module    = "authz-tables"
  }, var.enable_retention ? { "platform-janitor/lifecycle" = "ignore" } : {})
}
