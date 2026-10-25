# Shared IAM role for ALL Management Cluster CodeBuild projects
#
# This role is shared by all MC projects (mc01, mc02, ..., mcNN) to reduce
# IAM role proliferation as the number of MCs scales. Cluster names may be
# customized; all projects using this role write to its scoped log group.

data "aws_caller_identity" "mc_shared" {}

resource "aws_iam_role" "mc_codebuild_role" {
  name = "${local.iam_role_prefix}mc-codebuild-role"

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

resource "aws_iam_role_policy" "mc_codebuild_policy" {
  role = aws_iam_role.mc_codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup"]
        Resource = [
          for group in local.management_log_groups :
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:${group}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          for group in local.management_log_groups :
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.mc_shared.account_id}:log-group:${group}:*"
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
          "arn:aws:ssm:*:${data.aws_caller_identity.mc_shared.account_id}:parameter/infra/*"
        ]
      }
      ], length(local.management_assume_role_arns) > 0 ? [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = local.management_assume_role_arns
      }
      ] : [], local.management_same_account ? [
      # Permissions for same-account operations (when TARGET_ACCOUNT_ID == CENTRAL_ACCOUNT_ID)
      # In production, cross-account deployments should use OrganizationAccountAccessRole
      # These permissions allow Terraform to provision management cluster infrastructure
      {
        Effect = "Allow"
        Action = [
          # EC2/VPC - Full permissions for networking infrastructure
          "ec2:*",
          # EKS - Full permissions for cluster management
          "eks:*",
          # ECS - For bootstrap cluster operations
          "ecs:CreateCluster",
          "ecs:DeleteCluster",
          "ecs:DescribeClusters",
          "ecs:ListClusters",
          "ecs:PutClusterCapacityProviders",
          "ecs:TagResource",
          "ecs:UntagResource",
          "ecs:RegisterTaskDefinition",
          "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTaskDefinitions",
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          # Secrets Manager - For ECS bootstrap and cluster secrets
          "secretsmanager:*",
          # IAM - For creating cluster roles and policies
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagRole",
          "iam:TagPolicy",
          "iam:UntagRole",
          "iam:UntagPolicy",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:CreateServiceLinkedRole",
          "iam:GetServiceLinkedRoleDeletionStatus",
          "iam:DeleteServiceLinkedRole",
          # KMS - For encryption
          "kms:CreateKey",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation",
          "kms:DisableKeyRotation",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant",
          "kms:RetireGrant",
          # Logs - For EKS control plane logs and ECS task logs
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:ListTagsLogGroup",
          "logs:ListTagsForResource",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:PutRetentionPolicy",
          "logs:TagLogGroup",
          "logs:UntagLogGroup"
        ]
        Resource = "*"
      }
      ] : [], local.management_same_account ? [
      {
        # IAM PassRole restricted to EKS and ECS services only
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "eks.amazonaws.com",
              "ecs-tasks.amazonaws.com"
            ]
          }
        }
      }
    ] : [])
  })
}
