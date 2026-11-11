# =============================================================================
# ZOA Deployment Autodiscovery — SSM Parameter Store
# =============================================================================
# Written by RC Terraform into the Central account (primary + replica SSM
# regions). Parameter name is deployment_name (Seaplane config: us-east-1 or
# us-east-1-eph-<id>), not regional_id (eph-<id>-regional).
#
# The parameter stores a JSON object with the deployment's Function URL,
# invoker role ARN, and metadata. Multiple deployments (including ephemeral)
# coexist under the same /zoa/deployments/ prefix.
# =============================================================================

locals {
  deployment_ssm_value = jsonencode({
    access_url       = aws_lambda_function_url.access.function_url
    invoker_role_arn = aws_iam_role.invoker.arn
    region           = data.aws_region.current.region
    account_id       = data.aws_caller_identity.current.account_id
    deployment_name  = var.deployment_name
  })
}

resource "aws_ssm_parameter" "deployment" {
  provider    = aws.central_deployments
  name        = "/zoa/deployments/${var.deployment_name}"
  type        = "String"
  description = "ZOA deployment discovery for ${var.deployment_name}"

  value = local.deployment_ssm_value

  tags = merge(local.common_tags, {
    Name = "/zoa/deployments/${var.deployment_name}"
  })
}

resource "aws_ssm_parameter" "deployment_replica" {
  provider    = aws.central_deployments_replica
  name        = "/zoa/deployments/${var.deployment_name}"
  type        = "String"
  description = "ZOA deployment discovery replica for ${var.deployment_name}"

  value = local.deployment_ssm_value

  tags = merge(local.common_tags, {
    Name = "/zoa/deployments/${var.deployment_name}"
  })
}
