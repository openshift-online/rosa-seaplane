# =============================================================================
# ZOA per-VPC Lambda Module
# =============================================================================
# Deploys ZOA Lambda functions (api + worker) in a target VPC.
# Called once per VPC (RC + each MC). Each deployment has direct EKS API access
# to the cluster in that VPC — no cross-VPC or cross-account K8s API calls.
#
# Architecture (2 Lambdas per VPC):
#   - API Lambda: Function URL with native Go streaming. Handles CLI
#     requests and sync auto-approved TA execution.
#   - Worker Lambda: Standard handler. Handles all scheduled work (reconciler,
#     GC, reaper) and async TA execution via self-invocation from reconciler.
#
# Data layer (DynamoDB, S3, KMS) lives in the RC account. MC deployments assume
# the RC data_access role (DATA_STORE_ROLE_ARN) for DynamoDB and S3.
#
# Design decisions:
#   - Lambda timeout (300s) is a safety net ceiling. Real deadlines are enforced
#     in code via context.WithTimeout (tunable via env vars without code change).
#   - Worker self-invokes for TA execution (fan-out). Default worker reserved
#     concurrency is 10 (reconciler headroom + TA cap); tunable via variables (-1 in ephemeral).
#   - All timeouts are env-var tunable (RECONCILER_DEADLINE_SECONDS, etc.)
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  function_prefix = "${var.cluster_id}-zoa"

  common_env = merge({
    EXECUTION_TABLE                   = var.dynamodb_table_name
    AUDIT_TABLE                       = var.audit_table_name
    ARTIFACT_BUCKET                   = var.artifact_bucket_name
    KMS_KEY_ARN                       = var.kms_key_arn
    JOB_IMAGE                         = var.job_image_uri
    ZOA_JOBS_NAMESPACE                = var.zoa_jobs_namespace
    ZOA_TARGET_TYPE                   = var.target_type
    DYNAMODB_TTL_DAYS                 = tostring(var.dynamodb_ttl_days)
    TARGET_CLUSTER                    = var.cluster_id
    UPLOADER_ROLE_ARN                 = var.uploader_role_arn
    AWS_READ_ROLE_ARN                 = aws_iam_role.zoa_aws_read.arn
    AWS_WRITE_ROLE_ARN                = aws_iam_role.zoa_aws_write.arn
    EKS_CLUSTER_ENDPOINT              = var.eks_cluster_endpoint
    EKS_CLUSTER_CA                    = var.eks_cluster_ca
    EKS_CLUSTER_NAME                  = var.eks_cluster_name
    WRITE_COOLDOWN_SECONDS            = tostring(var.write_cooldown_seconds)
    MAX_CONCURRENT_PER_TARGET         = tostring(var.max_concurrent_per_target)
    ASYNC_SCHEDULING_OVERHEAD_SECONDS = tostring(var.async_scheduling_overhead_seconds)
    LOG_LEVEL                         = var.log_level
    }, var.data_access_role_arn != "" ? { DATA_STORE_ROLE_ARN = var.data_access_role_arn } : {},
    var.seaplane_db_endpoint != "" ? {
      SEAPLANE_DB_ENDPOINT = var.seaplane_db_endpoint
      SEAPLANE_DB_NAME     = var.seaplane_db_name
      SEAPLANE_DB_USERNAME = var.seaplane_db_username
    } : {},
    var.sessions_table_name != "" ? {
      SESSIONS_TABLE                 = var.sessions_table_name
      SESSION_IDLE_TIMEOUT_SECONDS   = tostring(var.session_idle_timeout_seconds)
      SESSION_STALE_CREATING_SECONDS = tostring(var.session_stale_creating_seconds)
  } : {})

  common_tags = {
    Component = "zoa"
    function  = "zoa"
    ManagedBy = "terraform"
    module    = "zoa-lambda"
    Cluster   = var.cluster_id
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Lambda execution (shared by both api and worker)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name        = "${local.function_prefix}-lambda"
  description = "Execution role for ZOA per-VPC Lambda functions in ${var.cluster_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-lambda-role"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${local.function_prefix}-dynamodb"
  role = aws_iam_role.lambda.id

  # Table names from RC; MC callers use credentials from assumed data_access.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable",
      ]
      Resource = concat(
        [
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.dynamodb_table_name}",
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.dynamodb_table_name}/index/*",
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.audit_table_name}",
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.audit_table_name}/index/*",
        ],
        var.sessions_table_name != "" ? [
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.sessions_table_name}",
          "arn:aws:dynamodb:${data.aws_region.current.region}:*:table/${var.sessions_table_name}/index/*",
        ] : [],
      )
    }]
  })
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "${local.function_prefix}-s3"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${var.artifact_bucket_arn}/executions/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:HeadBucket",
        ]
        Resource = var.artifact_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = "executions/*"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "lambda_kms" {
  name = "${local.function_prefix}-kms"
  role = aws_iam_role.lambda.id

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

resource "aws_iam_role_policy" "lambda_ecr" {
  name = "${local.function_prefix}-ecr"
  role = aws_iam_role.lambda.id

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

resource "aws_iam_role_policy" "lambda_sts" {
  name = "${local.function_prefix}-sts"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Resource = compact([
        var.uploader_role_arn,
        aws_iam_role.zoa_aws_read.arn,
        aws_iam_role.zoa_aws_write.arn,
        var.data_access_role_arn,
      ])
    }]
  })
}

# -----------------------------------------------------------------------------
# AWS TA Execution Roles
# Lambda assumes these roles when executing AWS TAs (ec2, eks, etc.)
# Each role has least-privilege for its scope (read or write).
# S3 artifact upload is included so async Jobs can upload output via the same creds.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "zoa_aws_read" {
  name = "${local.function_prefix}-aws-read"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-aws-read"
  })
}

resource "aws_iam_role_policy" "zoa_aws_read" {
  name = "read-permissions"
  role = aws_iam_role.zoa_aws_read.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:List*",
          "eks:Describe*",
          "eks:List*",
          "elasticloadbalancing:Describe*",
          "route53:List*",
          "route53:Get*",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
        ]
        Resource = "${var.artifact_bucket_arn}/executions/*"
      },
      {
        Effect   = "Allow"
        Action   = "kms:GenerateDataKey"
        Resource = var.kms_key_arn
      },
      ],
      var.seaplane_db_resource_arn != "" ? [{
        Effect = "Allow"
        Action = [
          "rds-db:connect",
        ]
        Resource = var.seaplane_db_resource_arn
      }] : []
    )
  })
}

resource "aws_iam_role" "zoa_aws_write" {
  name = "${local.function_prefix}-aws-write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-aws-write"
  })
}

# No inline policy for write role — no write TAs are implemented yet.
# When write TAs are added, attach a policy with the required actions here.
# The role exists so that Lambda env vars reference a valid ARN and STS
# AssumeRole can target it without Terraform changes.

# Worker self-invocation: reconciler invokes same worker Lambda for TA execution
resource "aws_iam_role_policy" "lambda_self_invoke" {
  name = "${local.function_prefix}-self-invoke"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.worker.arn
    }]
  })
}

resource "aws_iam_role_policy" "lambda_dlq" {
  name = "${local.function_prefix}-dlq"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.dlq.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# EKS Access Entry — grants Lambda IAM role access to the EKS cluster.
# The Lambda authenticates via STS presigned URL (same as aws-iam-authenticator).
# Without this, the K8s API rejects all requests from Lambda.
# -----------------------------------------------------------------------------

# EKS access entry: registers the Lambda IAM role as a K8s principal.
# Actual permissions are defined via kubernetes_cluster_role and kubernetes_role
# resources above (least-privilege RBAC managed by Terraform).
resource "aws_eks_access_entry" "lambda" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.lambda.arn
  type          = "STANDARD"

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-eks-access"
  })
}

# =============================================================================
# EKS Access Policy for ZOA Lambda
# =============================================================================
# The ideal approach is to use fine-grained Kubernetes RBAC (ClusterRole + Role)
# managed by the Terraform kubernetes provider. However, this requires network
# connectivity to the private EKS API endpoint, which CodeBuild (running in the
# central CI account) does not have.
#
# Current approach: AmazonEKSClusterAdminPolicy grants full K8s access. This is
# intentionally broad because no managed policy matches our exact permission set
# (namespaces:get, RBAC:create/delete/bind/escalate, SA/Secret/Job in zoa-jobs).
#
# The Lambda's Go code (ensureNamespace, createExecutionResources) already
# creates the zoa-jobs namespace, SAs, Roles, RoleBindings, and Jobs with
# precise RBAC scoping at runtime. The EKS policy here is only the "outer shell"
# that allows the Lambda IAM principal to authenticate to K8s.
#
# Future: When the pipeline runs in-VPC (e.g., CodeBuild in the target VPC or
# a Terraform Cloud agent), replace this with kubernetes provider-managed
# ClusterRole + Role for true least-privilege.
# =============================================================================

resource "aws_eks_access_policy_association" "lambda" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.lambda.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.lambda]
}

resource "aws_iam_role_policy" "lambda_eks" {
  name = "${local.function_prefix}-eks"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
      ]
      Resource = "arn:aws:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
    }]
  })
}

# -----------------------------------------------------------------------------
# SQS Dead Letter Queue
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                       = "${local.function_prefix}-dlq"
  message_retention_seconds  = 1209600 # 14 days, auto-cleaned
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-dlq"
  })
}

# -----------------------------------------------------------------------------
# Lambda: ZOA API (Function URL with IAM auth, native response streaming)
# -----------------------------------------------------------------------------
# Handles all CLI requests:
#   - POST /run → sync auto-approved TAs execute here directly
#   - GET /runs/{id} → status
#   - GET /runs/{id}/output → streaming download from S3
#   - GET /runs/{id}/logs → streaming download from S3
#   - GET /audit → audit log
#
# Uses native Go Lambda streaming (LambdaFunctionURLStreamingResponse) via
# the aws-lambda-go SDK. RESPONSE_STREAM on the Function URL enables downloads >6MB.

resource "aws_lambda_function" "api" {
  function_name = "${local.function_prefix}-api"
  description   = "ZOA API for ${var.cluster_id} - CLI requests, sync TAs, streaming downloads"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.lambda_image_uri
  architectures = ["x86_64"]
  timeout       = var.lambda_api_timeout
  memory_size   = var.lambda_memory_size

  reserved_concurrent_executions = var.lambda_api_concurrency

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.cluster_security_group_id]
  }

  environment {
    variables = merge(local.common_env, {
      HANDLER_MODE               = "api"
      EXECUTION_DEADLINE_SECONDS = tostring(var.lambda_api_timeout - 5)
    })
  }

  tags = merge(local.common_tags, {
    Name        = "${local.function_prefix}-api"
    HandlerMode = "api"
  })
}

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "RESPONSE_STREAM"
}

# -----------------------------------------------------------------------------
# Lambda: ZOA Worker (EventBridge + self-invoke for TA execution)
# -----------------------------------------------------------------------------
# Handles ALL scheduled and async work:
#   - EventBridge "reconciler" (1min): dispatch approved TAs, poll Jobs, timeouts
#   - EventBridge "gc" (5min): delete K8s resources for terminal executions
#   - Async self-invoke: execute approved TAs (fan-out from reconciler)
#
# Code-level deadlines (env var tunable without code change):
#   - Scheduled routes (reconciler/gc): RECONCILER_DEADLINE_SECONDS (55s)
#   - TA execution: EXECUTION_DEADLINE_SECONDS (295s)
#   - Batch size per tick: MAX_BATCH_PER_TICK (30)
#
# Default reserved worker concurrency 10: reconciler headroom + concurrent TA execs
# (see lambda_worker_concurrency; -1 = unreserved pool in ephemeral). Excess
# self-invocations queue in Lambda until a slot frees up.

resource "aws_lambda_function" "worker" {
  function_name = "${local.function_prefix}-worker"
  description   = "ZOA Worker for ${var.cluster_id} - reconciler, GC, TA execution"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.lambda_image_uri
  architectures = ["x86_64"]
  timeout       = var.lambda_worker_timeout
  memory_size   = var.lambda_memory_size

  reserved_concurrent_executions = var.lambda_worker_concurrency

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.cluster_security_group_id]
  }

  environment {
    variables = merge(local.common_env, {
      HANDLER_MODE = "worker"
      # Self-invocation: Go code reads AWS_LAMBDA_FUNCTION_NAME (auto-set by Lambda runtime)
      # Code-level deadlines (tunable without code change)
      RECONCILER_DEADLINE_SECONDS = tostring(var.reconciler_deadline_seconds)
      EXECUTION_DEADLINE_SECONDS  = tostring(var.lambda_worker_timeout - 5)
      MAX_BATCH_PER_TICK          = tostring(var.max_batch_per_tick)
    })
  }

  tags = merge(local.common_tags, {
    Name        = "${local.function_prefix}-worker"
    HandlerMode = "worker"
  })
}

# -----------------------------------------------------------------------------
# EventBridge Schedules — all target the Worker Lambda
# -----------------------------------------------------------------------------

resource "aws_scheduler_schedule" "reconciler" {
  name        = "${local.function_prefix}-reconciler"
  description = "Triggers ZOA reconciler for ${var.cluster_id} every 60 seconds"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(1 minute)"

  target {
    arn      = aws_lambda_function.worker.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ route = "reconciler" })

    retry_policy {
      maximum_retry_attempts = 2
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }

  state = "ENABLED"
}

resource "aws_scheduler_schedule" "gc" {
  name        = "${local.function_prefix}-gc"
  description = "Triggers ZOA garbage collection for ${var.cluster_id} every 5 minutes"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.worker.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ route = "gc" })

    retry_policy {
      maximum_retry_attempts = 2
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }

  state = "ENABLED"
}

# Reaper: same per-VPC Worker schedule as reconciler/GC. Session rows live in RC
# DynamoDB; each worker lists expired sessions and stops ECS tasks for this cluster only.
resource "aws_scheduler_schedule" "reaper" {
  name        = "${local.function_prefix}-reaper"
  description = "Triggers ZOA boundary session reaper for ${var.cluster_id} every 5 minutes"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.worker.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ route = "reaper" })

    retry_policy {
      maximum_retry_attempts = 2
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }

  state = "ENABLED"
}

# Worker reaper: StopTask on boundary ECS cluster in this VPC/account only.
resource "aws_iam_role_policy" "lambda_boundary_ecs_reaper" {
  name = "${local.function_prefix}-boundary-ecs-reaper"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
  })
}

# Worker reaper idle: correlate ECS Exec sessions (SSM) and terminal activity (CloudWatch).
resource "aws_iam_role_policy" "lambda_boundary_reaper_idle" {
  count = var.sessions_table_name != "" ? 1 : 0
  name  = "${local.function_prefix}-boundary-reaper-idle"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:DescribeSessions"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.cluster_id}/zoa-boundary/ssm-sessions:*"
      },
    ]
  })
}


# -----------------------------------------------------------------------------
# EventBridge Scheduler IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "scheduler" {
  name        = "${local.function_prefix}-scheduler"
  description = "EventBridge Scheduler for ZOA worker in ${var.cluster_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-scheduler-role"
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "${local.function_prefix}-scheduler-invoke"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.worker.arn
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}

# Explicit permission for EventBridge Scheduler → Worker invocation.
# Functionally redundant (scheduler role already has lambda:InvokeFunction)
# but makes the access model visible in the Lambda Console Permissions tab
# for auditability without cross-referencing IAM policies.
resource "aws_lambda_permission" "scheduler_invoke_worker" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.worker.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = "arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:schedule/default/${local.function_prefix}-*"
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups (365-day retention, KMS-encrypted)
# Alerting handled via CW Exporter → Prometheus → PrometheusRules
# Native Lambda metrics (Errors, Duration, Throttles, Invocations) are
# automatically available per FunctionName in the AWS/Lambda CW namespace.
# Custom business metrics emitted via EMF in the ZOA namespace.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "lambda_logs" {
  description             = "KMS key for ZOA Lambda CloudWatch log encryption (FedRAMP AU-09)"
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.function_prefix}-*"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-lambda-logs-kms"
  })
}

resource "aws_kms_alias" "lambda_logs" {
  name          = "alias/${local.function_prefix}-lambda-logs"
  target_key_id = aws_kms_key.lambda_logs.key_id
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.lambda_logs.arn

  depends_on = [aws_kms_key.lambda_logs]

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-api-logs"
  })
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${aws_lambda_function.worker.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.lambda_logs.arn

  depends_on = [aws_kms_key.lambda_logs]

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-worker-logs"
  })
}

# =============================================================================
# SSM Target Registration — Self-registers this cluster as a ZOA target
# =============================================================================
# RC clusters: Terraform writes this parameter (same account as Access Lambda).
# MC clusters: MC pipeline provisions RC SSM via mc-zoa-target-ssm-provisioning (see provision-mc-zoa-target-ssm.sh).

resource "aws_ssm_parameter" "zoa_target" {
  count = var.targets_ssm_prefix != "" ? 1 : 0
  name  = "${var.targets_ssm_prefix}/${var.cluster_id}"
  type  = "String"

  value = jsonencode({
    target_id           = var.cluster_id
    deployment_name     = var.deployment_name
    target_type         = var.target_type
    vpc_id              = var.vpc_id
    subnet_ids          = join(",", var.private_subnet_ids)
    security_group_id   = aws_security_group.boundary.id
    ecs_cluster_arn     = aws_ecs_cluster.boundary.arn
    task_definition_arn = aws_ecs_task_definition.boundary.arn
    function_url        = aws_lambda_function_url.api.function_url
    account_id          = data.aws_caller_identity.current.account_id
    region              = data.aws_region.current.region
    status              = "ready"
  })

  tags = merge(local.common_tags, {
    Name = "${local.function_prefix}-target-registration"
  })
}
