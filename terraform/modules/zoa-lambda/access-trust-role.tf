# RC-only shell for the ZOA Access Lambda execution role.
# Boundary trust policies in this module reference this role's ARN directly
# (aws_iam_role.access_lambda), not a constructed ARN string.
#
# This module does NOT attach session/ECS/DynamoDB policies — those live in
# module.zoa-access (policies + aws_lambda_function + invoker role).
# Destroy order: zoa-access first, then this role in zoa-lambda.

resource "aws_iam_role" "access_lambda" {
  count = var.target_type == "rc" ? 1 : 0

  name        = "${var.cluster_id}-zoa-access-lambda"
  description = "Execution role for ZOA Access Lambda in ${var.cluster_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.cluster_id}-zoa-access"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-access-lambda-role"
  })
}

locals {
  access_lambda_role_arn = var.target_type == "rc" ? aws_iam_role.access_lambda[0].arn : var.access_lambda_role_arn
}
