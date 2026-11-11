# =============================================================================
# KMS Key for ZOA Encryption
# =============================================================================
# Encrypts DynamoDB table and S3 bucket contents

resource "aws_kms_key" "zoa" {
  description             = "KMS key for ZOA outputs encryption"
  deletion_window_in_days = var.environment == "ephemeral" ? 7 : 30
  enable_key_rotation     = true

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-zoa"
      Component = "zoa"
    }
  )
}

resource "aws_kms_alias" "zoa" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.zoa.key_id
}

resource "aws_kms_key_policy" "zoa" {
  key_id = aws_kms_key.zoa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLocalLambdaKMS"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-zoa-lambda"
          }
        }
      },
      {
        Sid    = "AllowCrossAccountAWSRoleKMS"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
          StringLike = {
            "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-aws-*"
          }
        }
      },
      {
        Sid    = "AllowCrossAccountLambdaKMS"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
          StringLike = {
            "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-lambda"
          }
        }
      },
      {
        Sid    = "AllowLambdaServiceDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsBoundaryExec"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.regional_id}/zoa-boundary",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.regional_id}/zoa-boundary:*",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.regional_id}/zoa-boundary/ssm-sessions",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.regional_id}/zoa-boundary/ssm-sessions:*",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.regional_id}-zoa-access",
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.regional_id}-zoa-access:*",
            ]
          }
        }
      },
      {
        Sid    = "AllowCrossAccountCloudWatchLogsBoundaryExec"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              "arn:aws:logs:${data.aws_region.current.region}:*:log-group:/ecs/*/zoa-boundary",
              "arn:aws:logs:${data.aws_region.current.region}:*:log-group:/ecs/*/zoa-boundary:*",
              "arn:aws:logs:${data.aws_region.current.region}:*:log-group:/ecs/*/zoa-boundary/ssm-sessions",
              "arn:aws:logs:${data.aws_region.current.region}:*:log-group:/ecs/*/zoa-boundary/ssm-sessions:*",
            ]
          }
        }
      },
      {
        Sid    = "AllowLocalBoundaryRolesECSExecKMS"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-zoa-boundary-*"
          }
        }
      },
      {
        Sid    = "AllowCrossAccountBoundaryRolesECSExecKMS"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
          StringLike = {
            "aws:PrincipalArn" = "arn:*:iam::*:role/*-zoa-boundary-*"
          }
        }
      },
      {
        Sid    = "AllowCrossAccountMCCloudWatchLogsKMSDescribe"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
        }
      },
      {
        Sid    = "AllowCrossAccountMCCloudWatchLogsKMSCreateGrant"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:CreateGrant",
        ]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
    ]
  })
}

data "aws_caller_identity" "current" {}
