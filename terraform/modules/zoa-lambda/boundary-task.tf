data "aws_partition" "current" {}

resource "aws_ecs_task_definition" "boundary" {
  family                   = "${var.cluster_id}-zoa-boundary"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.boundary_cpu
  memory                   = var.boundary_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name        = local.boundary_container_name
      image       = var.boundary_image
      essential   = true
      stopTimeout = 30
      user        = "1000"

      environment = flatten([
        {
          name  = "ZOA_API_URL"
          value = aws_lambda_function_url.api.function_url
        },
        {
          name  = "ZOA_TARGET"
          value = var.cluster_id
        },
        {
          name  = "ZOA_DEPLOYMENT"
          value = var.deployment_name
        },
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.region
        },
        {
          name  = "ZOA_BREAKGLASS_ROLE_ARN"
          value = ""
        },
        {
          name  = "HOME"
          value = "/home/sre"
        },
        {
          name  = "CLAUDE_CODE_USE_BEDROCK"
          value = "1"
        },
        {
          name  = "DISABLE_AUTOUPDATER"
          value = "1"
        },
        {
          name  = "ZOA_ECS_EXEC_COMMAND"
          value = var.boundary_ecs_exec_interactive_command
        },
        {
          name  = "ANTHROPIC_MODEL"
          value = var.claude_code_bedrock_primary_model
        },
      ])

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.boundary.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "container"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  tags = local.common_tags

  depends_on = [
    aws_lambda_function.api,
    aws_lambda_function_url.api,
  ]
}

resource "aws_iam_role" "task" {
  name = "${var.cluster_id}-zoa-boundary-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "task_ssm" {
  name = "ssm-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMMessages"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsDescribeGroups"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsExecSessions"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.boundary_exec.arn,
          "${aws_cloudwatch_log_group.boundary_exec.arn}:*",
        ]
      },
      {
        Sid    = "KMSForECSExec"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = local.boundary_encryption_kms_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "task_ssm_params" {
  name = "ssm-params"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "SSMParameterRead"
      Effect = "Allow"
      Action = [
        "ssm:GetParameter"
      ]
      Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/zoa/deployments/*"
    }]
  })
}

resource "aws_iam_role_policy" "task_lambda" {
  name = "lambda-function-url"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeFunctionURL"
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunctionUrl",
      ]
      Resource = aws_lambda_function.api.arn
      Condition = {
        StringEquals = {
          "lambda:FunctionUrlAuthType" = "AWS_IAM"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "task_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListInferenceProfiles",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:*:*:inference-profile/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:*:foundation-model/*",
        ]
      },
      {
        Sid    = "BedrockGetInferenceProfile"
        Effect = "Allow"
        Action = ["bedrock:GetInferenceProfile"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:application-inference-profile/*",
        ]
      },
      {
        Sid    = "AllowMarketplaceSubscriptionViaBedrock"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:CalledViaLast" = "bedrock.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "task_breakglass" {
  count = length(var.breakglass_role_arns) > 0 ? 1 : 0
  name  = "breakglass-assume-role"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "BreakglassAssumeRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.breakglass_role_arns
    }]
  })
}
