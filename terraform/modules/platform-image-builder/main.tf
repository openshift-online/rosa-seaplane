provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false
}

data "aws_caller_identity" "current" {}

locals {
  # When name_prefix is set (e.g., "abc123"), platform-image resources use that prefix.
  name_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  common_tags = {
    function  = "platform-image"
    module    = "platform-image-builder"
    ManagedBy = "terraform"
  }
}

# Use shared GitHub Connection (created in central-account-bootstrap)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [
    aws_iam_role_policy.build_platform_image_policy
  ]
}

# CodeBuild Project - Build Platform Image
resource "aws_codebuild_project" "build_platform_image" {
  depends_on             = [time_sleep.iam_propagation]
  name                   = "${local.name_prefix}build-platform-image"
  service_role           = aws_iam_role.build_platform_image_role.arn
  build_timeout          = 30
  concurrent_build_limit = 1 # Prevent parallel executions
  tags                   = local.common_tags

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Required for docker build

    environment_variable {
      name  = "PLATFORM_ECR_REPO"
      value = var.platform_ecr_repo
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repository}.git"
    git_clone_depth = 0 # Full history (image tag derives from Dockerfile content hash)
    buildspec       = "terraform/modules/platform-image-builder/buildspec-build-image.yml"

    git_submodules_config {
      fetch_submodules = false
    }

    auth {
      type     = "CODECONNECTIONS"
      resource = data.aws_codestarconnections_connection.github.arn
    }
  }
}
