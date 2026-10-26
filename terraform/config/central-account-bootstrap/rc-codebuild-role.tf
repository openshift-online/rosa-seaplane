# Shared IAM role for Regional Cluster CodeBuild projects
#
# This role is used by SDK-created RC CodeBuild projects (one per region).
# The role name is referenced by ARN in the SDK provisioner script.

data "aws_caller_identity" "rc_shared" {}

locals {
  zoa_central_deployments_ssm_parameter_arns = [
    for region in distinct([
      var.zoa_central_deployments_primary_region,
      var.zoa_central_deployments_replica_region,
    ]) : "arn:aws:ssm:${region}:${data.aws_caller_identity.rc_shared.account_id}:parameter/zoa/deployments/*"
  ]
}

resource "aws_iam_role" "rc_codebuild_role" {
  name = "${local.iam_role_prefix}rc-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rc_codebuild_policy" {
  role = aws_iam_role.rc_codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup"]
        Resource = [
          for group in local.regional_log_groups :
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.rc_shared.account_id}:log-group:${group}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          for group in local.regional_log_groups :
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.rc_shared.account_id}:log-group:${group}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::terraform-state-*",
          "arn:aws:s3:::terraform-state-*/*"
        ]
      },
      {
        Sid    = "PipelineArtifactRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]
        Resource = [
          module.codepipeline_shared.artifact_bucket_arn,
          "${module.codepipeline_shared.artifact_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:*:${data.aws_caller_identity.rc_shared.account_id}:parameter/infra/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:AddTagsToResource",
          "ssm:RemoveTagsFromResource",
          "ssm:ListTagsForResource",
        ]
        Resource = local.zoa_central_deployments_ssm_parameter_arns
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
      {
        # Match upstream/main: RC Terraform's central provider needs DNS access.
        Effect   = "Allow"
        Action   = ["route53:*"]
        Resource = "*"
      }
      ], length(local.regional_assume_role_arns) > 0 ? [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = local.regional_assume_role_arns
      }
      ] : [], local.regional_same_account ? [
      # Preserve the upstream RC provisioning permissions for deployments where
      # TARGET_ACCOUNT_ID is the central account and no child role is assumed.
      {
        Effect = "Allow"
        Action = [
          "logs:*",
          "ec2:*",
          "eks:*",
          "iam:*",
          "s3:*",
          "ecs:*",
          "kms:*",
          "apigateway:*",
          "iot:*",
          "rds:*",
          "elasticache:*",
          "secretsmanager:*",
          "elasticloadbalancing:*",
          "autoscaling:*",
          "cloudwatch:*",
          "acm:*",
          "tag:*",
          "lambda:*",
          "sqs:*",
          "scheduler:*",
          "dynamodb:*"
        ]
        Resource = "*"
      }
    ] : [])
  })
}
