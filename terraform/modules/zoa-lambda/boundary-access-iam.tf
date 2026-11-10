locals {
  boundary_access_trust_principals = [local.access_lambda_role_arn]

  boundary_cluster_name    = element(split("/", aws_ecs_cluster.boundary.arn), 1)
  boundary_task_arn_prefix = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task/${local.boundary_cluster_name}/"
}

resource "aws_iam_role" "boundary_access" {
  name        = "${var.cluster_id}-zoa-boundary-access"
  description = "Cross-account role for RC ZOA Access Lambda to manage boundary ECS tasks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = local.boundary_access_trust_principals
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-access-role"
  })
}

resource "aws_iam_role_policy" "boundary_access_ecs" {
  name = "boundary-ecs-lifecycle"
  role = aws_iam_role.boundary_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTaskOnBoundaryCluster"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "${aws_ecs_task_definition.boundary.arn_without_revision}:*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Component" = "zoa"
          }
        }
      },
      {
        Sid    = "StopAndDescribeBoundaryTasks"
        Effect = "Allow"
        Action = [
          "ecs:StopTask",
          "ecs:DescribeTasks",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "ecs:cluster" = aws_ecs_cluster.boundary.arn
          }
        }
      },
      {
        Sid      = "TagBoundaryTasks"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "${local.boundary_task_arn_prefix}*"
      },
      {
        Sid    = "PassBoundaryTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.execution.arn,
          aws_iam_role.task.arn,
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "exec_scoped" {
  name        = "${var.cluster_id}-zoa-boundary-exec-scoped"
  description = "Role vended via Access session join for per-task ECS Exec (scoped by session policy)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = local.boundary_access_trust_principals
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_id}-zoa-boundary-exec-scoped-role"
  })
}

# Credentials for this role are vended to the operator laptop on session join (RC Access
# Lambda sts:AssumeRole). Access also attaches a session policy (rosa-seaplane-zoa
# pkg/execcreds) that narrows ecs:ExecuteCommand to a single task ARN; the statements
# below are the role baseline when no session policy is applied.
#
# SSMMessagesForExec uses Resource = "*" on purpose. Interactive ECS Exec from the
# client requires ssmmessages:* channel APIs (session-manager-plugin) in addition to
# ecs:ExecuteCommand. AWS does not model those channel actions with per-task ARNs, so
# tightening Resource here would break join/exec without adding a meaningful IAM boundary
# (task scope is enforced on the ecs:ExecuteCommand and ecs:DescribeTasks statements).
resource "aws_iam_role_policy" "exec_scoped_base" {
  name = "ecs-exec-boundary"
  role = aws_iam_role.exec_scoped.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ExecuteCommandOnBoundaryCluster"
        Effect = "Allow"
        Action = ["ecs:ExecuteCommand"]
        Resource = [
          aws_ecs_cluster.boundary.arn,
          "${local.boundary_task_arn_prefix}*",
        ]
      },
      {
        Sid      = "DescribeBoundaryTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "${local.boundary_task_arn_prefix}*"
      },
      {
        Sid    = "SSMMessagesForExec"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Sid    = "KMSForECSExecChannel"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = local.boundary_encryption_kms_arn
      },
    ]
  })
}
