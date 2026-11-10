# =============================================================================
# ZOA Access Lambda Module — RC-Only Session Management
# =============================================================================
# Deploys the ZOA Access Lambda with a Function URL (IAM auth) and an
# Central-account-trusted invoker role for cross-account SRE access.
# This runs in the RC account ONLY with NO VPC attachment.
#
# The Access Lambda uses the same container image as api/worker Lambdas
# with HANDLER_MODE=access. It handles:
#   - Session lifecycle (start, stop, list, history)
#   - Target discovery (list targets within a deployment)
#   - Approval stubs (501 until approval workflow epic)
#   - Identity recording (SigV4 caller → DynamoDB)
#
# Architecture: SRE laptop → sts:AssumeRole (invoker) → Function URL → Lambda → DynamoDB + ECS
#
# Cross-account access: SREs authenticate in the environment Central Account,
# then assume this invoker role in the RC account to call the Function URL.
# Trust is scoped to configured role names in the central account only.
#
# The Lambda execution role shell is created in module.zoa-lambda (RC only) so boundary
# trust policies reference a real aws_iam_role ARN. This module attaches policies and
# the Access Lambda function to that role.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  function_name = "${var.regional_id}-zoa-access"

  common_tags = merge(var.tags, {
    Component = "zoa"
    function  = "zoa"
    ManagedBy = "terraform"
    module    = "zoa-access"
    Region    = var.regional_id
  })

}

# =============================================================================
# CloudWatch Log Group (encrypted with shared ZOA CMK)
# =============================================================================

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "${local.function_name}-logs"
  })
}

# =============================================================================
# Lambda Function — HANDLER_MODE=access (no VPC)
# =============================================================================

locals {
  lambda_role_arn  = var.lambda_execution_role_arn
  lambda_role_name = var.lambda_execution_role_name
  lambda_role_id   = var.lambda_execution_role_name
}

resource "aws_lambda_function" "access" {
  function_name = local.function_name
  description   = "ZOA Access Lambda for ${var.regional_id} - session lifecycle, target discovery"
  role          = local.lambda_role_arn
  package_type  = "Image"
  image_uri     = var.image_uri
  # Must match zoa-lambda (x86_64) and quay.io/rrp-dev-ci/zoa-lambda image builds (linux/amd64).
  architectures = ["x86_64"]
  timeout       = 30
  memory_size   = 256

  reserved_concurrent_executions = var.lambda_access_concurrency

  environment {
    variables = {
      HANDLER_MODE                     = "access"
      SESSIONS_TABLE                   = var.sessions_table_name
      TARGETS_SSM_PREFIX               = var.targets_ssm_prefix
      AUDIT_TABLE                      = var.audit_table_name
      KMS_KEY_ARN                      = var.kms_key_arn
      DEPLOYMENT_NAME                  = var.deployment_name
      ZOA_ECS_EXEC_COMMAND             = var.boundary_ecs_exec_command
      EXEC_SCOPED_ROLE_ARN             = var.exec_scoped_role_arn
      EXEC_CREDENTIAL_DURATION_SECONDS = "3600"
      SESSION_MAX_DURATION_HOURS       = tostring(var.session_max_duration_hours)
      SESSION_IDLE_TIMEOUT_SECONDS     = tostring(var.session_idle_timeout_seconds)
    }
  }

  tags = merge(local.common_tags, {
    Name        = local.function_name
    HandlerMode = "access"
  })
}

# =============================================================================
# Function URL (IAM auth) — replaces API Gateway
# =============================================================================
# Function URL with AWS_IAM auth type provides:
# - SigV4 authentication (unauthenticated requests rejected before code runs)
# - Native response streaming (APIGW HTTP API does not support streaming)
# - One fewer service in the critical path (simpler failure domain)
# - No custom domain needed (SSM autodiscovery provides the URL directly)

resource "aws_lambda_function_url" "access" {
  function_name      = aws_lambda_function.access.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "RESPONSE_STREAM"
}

# Allow the invoker role to call the Function URL (resource-based policy).
# AWS requires both InvokeFunctionUrl and InvokeFunction (InvokedViaFunctionUrl) since Oct 2025.
resource "aws_lambda_permission" "invoker" {
  statement_id           = "AllowInvokerRole"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.access.function_name
  principal              = aws_iam_role.invoker.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "invoker_invoke_function" {
  statement_id             = "AllowInvokerRoleInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.access.function_name
  principal                = aws_iam_role.invoker.arn
  invoked_via_function_url = true
}

# =============================================================================
# Central-Trusted Invoker Role — Cross-Account SRE Access
# =============================================================================
# SREs use Central Account credentials (pipeline role or SAML hub roles),
# then assume this role in the RC account to call the Function URL.

locals {
  trusted_assumer_role_names = concat(
    var.trusted_assumer_role_names,
    [
      for suffix in var.trusted_assumer_role_name_suffixes :
      "${var.central_account_id}-${suffix}"
    ]
  )
  trusted_assumer_principal_arns = [
    for role_name in local.trusted_assumer_role_names :
    "arn:aws:iam::${var.central_account_id}:role/${role_name}"
  ]
}

resource "aws_iam_role" "invoker" {
  name        = "${local.function_name}-invoker"
  description = "Central-trusted role for SRE access to ZOA Access Lambda Function URL in ${var.regional_id}"

  lifecycle {
    precondition {
      condition     = length(local.trusted_assumer_role_names) > 0
      error_message = "At least one trusted_assumer_role_names or trusted_assumer_role_name_suffixes entry is required. IAM rejects trust policies with missing principals; each name must exist in the central account."
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = local.trusted_assumer_principal_arns
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:PrincipalAccount" = var.central_account_id
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_name}-invoker-role"
  })
}

resource "aws_iam_role_policy" "invoker_function_url" {
  name = "${local.function_name}-invoker-function-url"
  role = aws_iam_role.invoker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunctionUrl"
        Resource = aws_lambda_function.access.arn
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.access.arn
        Condition = {
          Bool = {
            "lambda:InvokedViaFunctionUrl" = "true"
          }
        }
      },
    ]
  })
}

# =============================================================================
# IAM policies on the Access Lambda execution role
# =============================================================================
# Role shell (aws_iam_role + lambda.amazonaws.com trust) is in module.zoa-lambda
# access-trust-role.tf (RC). This module attaches least-privilege inline policies
# and the Access Lambda function to that role by name/ARN from module outputs.

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = local.lambda_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB: Read/Write sessions, Read targets, Write audit
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${local.function_name}-dynamodb"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SessionsReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable",
        ]
        Resource = [
          "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.sessions_table_name}",
          "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.sessions_table_name}/index/*",
        ]
      },
      # Targets read via SSM (see lambda_ssm policy below)
      {
        Sid    = "AuditWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
        ]
        Resource = [
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.audit_table_name}",
        ]
      },
    ]
  })
}

# ECS: RunTask, StopTask, DescribeTasks for boundary session management
resource "aws_iam_role_policy" "lambda_ecs" {
  name = "${local.function_name}-ecs"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTaskOnTaggedClusterAndTaskDef"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "${var.boundary_task_definition_arn_prefix}:*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Component" = "zoa"
          }
        }
      },
      {
        Sid    = "StopAndDescribeTasksInBoundaryCluster"
        Effect = "Allow"
        Action = [
          "ecs:StopTask",
          "ecs:DescribeTasks",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "ecs:cluster" = var.boundary_ecs_cluster_arn
          }
        }
      },
      {
        Sid      = "TagBoundaryTasks"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task/${var.regional_id}-zoa-boundary/*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}

# STS: cross-account boundary ECS + exec credential vending (MC targets).
# Resource patterns use mc account id + *-zoa-boundary-* role names (not per-MC role ARNs)
# so RC zoa-access can apply while MC boundary IAM is still being created in parallel pipelines.
resource "aws_iam_role_policy" "lambda_sts" {
  name = "${local.function_name}-sts"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeExecScopedRoles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = concat(
          [var.exec_scoped_role_arn],
          [for account_id in var.mc_account_ids : "arn:aws:iam::${account_id}:role/*-zoa-boundary-exec-scoped"],
        )
      },
      {
        Sid    = "AssumeBoundaryAccessRoles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          for account_id in var.mc_account_ids :
          "arn:aws:iam::${account_id}:role/*-zoa-boundary-access"
        ]
      },
    ]
  })
}

# SSM: Deployment discovery (Central Account) and target registration (RC Account)
resource "aws_iam_role_policy" "lambda_ssm" {
  name = "${local.function_name}-ssm"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DeploymentDiscovery"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/zoa/deployments/*"
      },
      {
        Sid    = "TargetDiscovery"
        Effect = "Allow"
        Action = [
          "ssm:GetParametersByPath",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/zoa/targets/*"
      },
    ]
  })
}

# KMS: Encrypt/decrypt with the ZOA KMS key
resource "aws_iam_role_policy" "lambda_kms" {
  name = "${local.function_name}-kms"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      Resource = var.kms_key_arn
    }]
  })
}

# ECR: Pull Lambda container image
resource "aws_iam_role_policy" "lambda_ecr" {
  name = "${local.function_name}-ecr"
  role = local.lambda_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "arn:aws:ecr:*:*:repository/*-zoa-lambda"
    }]
  })
}
