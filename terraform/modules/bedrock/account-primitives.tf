# --- Foundation model agreements ---------------------------------------------
# Ephemeral environments share AWS accounts, so multiple stacks race for
# account-scoped singletons. data.external probes skip create when the object
# already exists — skipped resources are NOT imported into state, so destroying
# one ephemeral stack does not remove account-wide agreements.
#
# Non-ephemeral environments (integration, stage, production) have dedicated
# accounts: resources are created normally and owned in Terraform state.
# See README.md § "Shared pool accounts" for limitations of the ephemeral path.

data "external" "bedrock_agreement_exists" {
  for_each = var.environment == "ephemeral" ? local.bedrock_agreement_entries : {}

  program = local.account_primitive_check_program

  query = {
    check    = "agreement"
    model_id = each.value.model_id
    region   = data.aws_region.current.region
  }
}

locals {
  # Ephemeral: skip if probe says exists. Non-ephemeral: create all.
  bedrock_agreement_entries_to_create = {
    for key, entry in local.bedrock_agreement_entries :
    key => entry
    if var.environment != "ephemeral" || try(data.external.bedrock_agreement_exists[key].result.exists, "false") != "true"
  }
}

# --- Bedrock cost budget (one name per account) ------------------------------

data "external" "bedrock_budget_exists" {
  count = var.enable_cost_budget && var.environment == "ephemeral" ? 1 : 0

  program = local.account_primitive_check_program

  query = {
    check       = "budget"
    account_id  = data.aws_caller_identity.current.account_id
    budget_name = var.budget_name
  }
}

locals {
  bedrock_budget_already_exists = length(data.external.bedrock_budget_exists) > 0 && (
    data.external.bedrock_budget_exists[0].result.exists == "true"
  )
  # Ephemeral: skip if probe says exists. Non-ephemeral: create if enabled.
  create_bedrock_cost_budget = var.enable_cost_budget && (
    var.environment != "ephemeral" || !local.bedrock_budget_already_exists
  )
}
