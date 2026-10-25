# =============================================================================
# IAM Roles and Policies for Platform Image Builder
# =============================================================================

# IAM Role for Build Platform Image CodeBuild Project
# Scoped to minimum permissions for building and pushing container images
resource "aws_iam_role" "build_platform_image_role" {
  name = "${local.name_prefix}build-image-role"
  tags = local.common_tags

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

resource "aws_iam_role_policy" "build_platform_image_policy" {
  role = aws_iam_role.build_platform_image_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name_prefix}build-platform-image*"
      },
      {
        Sid    = "ECRPublicAuthorization"
        Effect = "Allow"
        Action = [
          "ecr-public:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPublicPlatformRepository"
        Effect = "Allow"
        Action = [
          "ecr-public:DescribeImages",
          "ecr-public:BatchCheckLayerAvailability",
          "ecr-public:PutImage",
          "ecr-public:InitiateLayerUpload",
          "ecr-public:UploadLayerPart",
          "ecr-public:CompleteLayerUpload"
        ]
        Resource = var.platform_ecr_repo_arn
      },
      {
        Sid      = "ECRPublicBearerToken"
        Effect   = "Allow"
        Action   = "sts:GetServiceBearerToken"
        Resource = "*"
      },
      {
        Sid    = "GitHubConnectionAccess"
        Effect = "Allow"
        Action = [
          "codestar-connections:GetConnection",
          "codestar-connections:GetConnectionToken",
          "codestar-connections:UseConnection"
        ]
        Resource = var.github_connection_arn
      }
    ]
  })
}
