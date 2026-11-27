# =============================================================================
# API Gateway REST API
#
# Creates a REST API with AWS_IAM authentication and a single {proxy+}
# catch-all resource that forwards all requests to the backend.
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    function  = "platform-api"
    module    = "api-gateway"
    ManagedBy = "terraform"
  }
}

# -----------------------------------------------------------------------------
# REST API
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.regional_id}-api"
  description = var.api_description

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api"
  })
}

# -----------------------------------------------------------------------------
# Proxy Resource: {proxy+}
#
# Catches all paths and forwards them to the backend.
# The backend service handles its own routing.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

# -----------------------------------------------------------------------------
# Method: ANY on {proxy+}
#
# Accepts all HTTP methods with AWS_IAM authentication.
# Requires SigV4 signed requests (use awscurl for testing).
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# -----------------------------------------------------------------------------
# Root Resource Method: ANY on /
#
# Handle requests to the root path (e.g., health checks at /)
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "AWS_IAM"
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # Ensure deployment happens after all resources are created
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
    aws_api_gateway_rest_api_policy.main,
  ]

  # Force new deployment when configuration changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_method.root.id,
      aws_api_gateway_integration.proxy.id,
      aws_api_gateway_integration.root.id,
      aws_api_gateway_rest_api_policy.main.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# API Gateway Account — CloudWatch logging role (account-level, one per region)
#
# API Gateway requires an account-level IAM role before any stage can write
# access logs to CloudWatch. Without it, access_log_settings on the stage is
# silently ignored.
#
# That setting is an AWS singleton: exactly one cloudwatchRoleArn per AWS
# account and region, shared by every REST API in the account — including the
# RHOBS gateway, which has no account resource of its own. This module used to
# declare it, which made every regional cluster state a competing owner of one
# shared value: the newest apply won, and a teardown cleared the setting for
# every surviving cluster in the account, because the provider's delete
# unconditionally resets /cloudwatchRoleArn without checking whether the stored
# ARN is still the live one.
#
# The role and the account settings are therefore an account-level prerequisite
# provisioned once per AWS account and region, outside this repository, with a
# lifetime longer than any cluster — and provisioned before the first cluster
# is deployed into the account. This module consumes them and manages neither.
# See docs/design/api-gateway-account-ownership.md.
# -----------------------------------------------------------------------------

# Ownership handover. `removed` forgets the previous per-cluster copies on the
# next apply without destroying anything — in particular without triggering the
# account reset. Harmless on a state that never had them, and a no-op once the
# state has applied this change. Keep until every regional cluster state has
# applied at least once.
removed {
  from = aws_api_gateway_account.main

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.api_gateway_cloudwatch

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.api_gateway_cloudwatch

  lifecycle {
    destroy = false
  }
}

# The prerequisite is mandatory, not optional: aws_api_gateway_method_settings
# below enables execution logging, and API Gateway rejects that with
# "CloudWatch Logs role ARN must be set in account settings to enable logging"
# while the account has no logging role. An account must therefore be
# provisioned before the first regional cluster is deployed into it.
#
# This block is an advisory diagnostic, not a gate and not a policy evaluator.
# It reads the role by name so the plan names a missing prerequisite instead of
# leaving an opaque BadRequestException at apply time, and text-matches the
# trust policy. A scoped data source inside `check` reports a read failure as a
# warning rather than an error.
#
# It does NOT verify that the account's cloudwatchRoleArn setting exists or
# points at this role, that the managed policy is attached, that the trust
# policy actually permits the assume (effects, actions and conditions are not
# evaluated), or that any log event is delivered. Those need a live account.
# See docs/design/api-gateway-account-ownership.md ("Diagnostic scope").
check "api_gateway_account_logging_role" {
  data "aws_iam_role" "api_gateway_cloudwatch" {
    name = var.cloudwatch_role_name
  }

  assert {
    condition     = can(regex("apigateway\\.amazonaws\\.com", data.aws_iam_role.api_gateway_cloudwatch.assume_role_policy))
    error_message = "IAM role ${var.cloudwatch_role_name} exists but its trust policy does not mention apigateway.amazonaws.com. This is a text match on the trust policy only: it does not evaluate effects or conditions, the attached permissions, or the account's cloudwatchRoleArn setting."
  }
}

# =============================================================================
# FedRAMP AU-09: KMS Key for API Gateway Access Log Encryption
# =============================================================================

resource "aws_kms_key" "api_gateway_logs" {
  description             = "KMS key for API Gateway CloudWatch log encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/api-gateway/${var.regional_id}/*",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:API-Gateway-Execution-Logs_*"
            ]
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-gateway-logs"
  })
}

resource "aws_kms_alias" "api_gateway_logs" {
  name          = "alias/${var.regional_id}-api-gateway-logs"
  target_key_id = aws_kms_key.api_gateway_logs.key_id
}

# CloudWatch Log Group for API Gateway access logs (FedRAMP AU-02)
resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/api-gateway/${var.regional_id}/${var.stage_name}/access"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.api_gateway_logs.arn

  depends_on = [aws_kms_key.api_gateway_logs]

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-access-logs"
  })

  lifecycle {
    # NOTE: prevent_destroy breaks ephemeral environment teardown
    # prevent_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = var.stage_name

  # FedRAMP AU-02: Enable access logging to capture caller identity, request
  # path, response codes, and latency for all API Gateway requests.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      caller             = "$context.identity.caller"
      user               = "$context.identity.user"
      userArn            = "$context.identity.userArn"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      errorMessage       = "$context.error.message"
      errorType          = "$context.error.responseType"
      integrationLatency = "$context.integrationLatency"
      responseLatency    = "$context.responseLatency"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-${var.stage_name}"
  })

  # The account-level logging role is a prerequisite of the account, not of
  # this stage, so there is nothing in this configuration to order against.
  depends_on = [aws_cloudwatch_log_group.api_gateway_access]
}

# -----------------------------------------------------------------------------
# FedRAMP AC-08: System Use Notification
#
# Injects a DoD/FedRAMP-compliant use-notification banner into all API Gateway
# 4XX and DEFAULT responses so that unauthenticated or unauthorized callers
# receive the required warning before being granted any access.
# -----------------------------------------------------------------------------

locals {
  system_use_notification = "WARNING: This system is for authorized use only. Users (authorized or unauthorized) have no explicit or implicit expectation of privacy. Any or all uses of this system and all files on this system may be intercepted, monitored, recorded, copied, audited, inspected, and disclosed to authorized site, company, and law enforcement personnel, as well as authorized officials of other agencies. By using this system, the user consents to such interception, monitoring, recording, copying, auditing, inspection, and disclosure at the discretion of authorized site or company personnel. Unauthorized or improper use of this system may result in civil and criminal penalties and administrative or disciplinary action, as appropriate."
}

resource "aws_api_gateway_gateway_response" "unauthorized" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }

  response_templates = {
    "application/json" = jsonencode({
      message               = "Unauthorized"
      systemUseNotification = local.system_use_notification
    })
  }
}

resource "aws_api_gateway_gateway_response" "access_denied" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "ACCESS_DENIED"
  status_code   = "403"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }

  response_templates = {
    "application/json" = jsonencode({
      message               = "Access Denied"
      systemUseNotification = local.system_use_notification
    })
  }
}

resource "aws_api_gateway_gateway_response" "default_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_4XX"

  response_parameters = {
    "gatewayresponse.header.Warning"                   = "'${local.system_use_notification}'"
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }

  response_templates = {
    "application/json" = jsonencode({
      message               = "Request Error"
      systemUseNotification = local.system_use_notification
    })
  }
}

# -----------------------------------------------------------------------------
# FedRAMP AU-09: API Gateway Execution Log Group
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "api_gateway_execution" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.main.id}/${var.stage_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.api_gateway_logs.arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-api-execution-logs"
  })
}

# -----------------------------------------------------------------------------
# FedRAMP CM-07: Least Functionality — API Gateway Method Settings
#
# Restrict unnecessary capabilities: enable detailed metrics and throttling,
# disable execution logging at the method level to avoid PII in logs, and
# enforce that only necessary methods/capabilities are active.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_settings" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = var.metrics_enabled
    logging_level          = var.logging_level
    data_trace_enabled     = var.data_trace_enabled
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }

  depends_on = [aws_cloudwatch_log_group.api_gateway_execution]
}
