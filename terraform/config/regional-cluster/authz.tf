variable "authz_tables" {
  description = "Same-account, same-region authz table names: retained (authz-storage) or created here when enable_ephemeral_authz_tables. Null disables API IAM."
  type = object({
    policies = string
    global   = string
    regional = string
  })
  default = null
  validation {
    condition = var.authz_tables == null ? true : (
      length(distinct(values(var.authz_tables))) == 3 && alltrue([
        for name in values(var.authz_tables) : can(regex("^[A-Za-z0-9_.-]{3,255}$", name))
      ])
    )
    error_message = "Supply three distinct valid DynamoDB table names, not ARNs."
  }
}

variable "enable_ephemeral_authz_tables" {
  description = "Create authz_tables in this RC state, destroyed with the RC. Non-production only; production uses retained authz-storage."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_ephemeral_authz_tables || var.authz_tables != null
    error_message = "enable_ephemeral_authz_tables requires authz_tables."
  }
}

# Non-production RCs own disposable tables so teardown leaves nothing behind.
module "ephemeral_authz_tables" {
  count            = var.enable_ephemeral_authz_tables ? 1 : 0
  source           = "../../modules/authz-tables"
  table_names      = var.authz_tables
  enable_retention = false
}

data "aws_partition" "current" {}

locals {
  authz_tables = var.authz_tables == null ? {} : var.authz_tables
  authz_table_arns = [for name in values(local.authz_tables) :
    "arn:${data.aws_partition.current.partition}:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${name}"
  ]
}

resource "aws_iam_role" "platform_api_authz" {
  count = var.authz_tables == null ? 0 : 1
  name  = "${var.regional_id}-platform-api-authz"
  tags = {
    function = "authorization"
    module   = "regional-cluster"
  }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "platform_api_authz" {
  count = var.authz_tables == null ? 0 : 1
  name  = "authz-tables"
  role  = aws_iam_role.platform_api_authz[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # DynamoDB transactions authorize their constituent item operations.
      Action = [
        "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query",
        "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:ConditionCheckItem"
      ]
      Resource = local.authz_table_arns
    }]
  })
}

resource "aws_eks_pod_identity_association" "platform_api_authz" {
  count           = var.authz_tables == null ? 0 : 1
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "platform-api"
  service_account = "platform-api-sa"
  role_arn        = aws_iam_role.platform_api_authz[0].arn
  tags = {
    function = "authorization"
    module   = "regional-cluster"
  }
}
