# =============================================================================
# ECR Repositories for ZOA Container Images
# =============================================================================
# Private ECR repos with OU-scoped cross-account pull access.
# MC Lambdas (different account, same region) pull using the same image URI.
# Images are mirrored from the source registry via skopeo (registry-to-registry, no daemon).

resource "aws_ecr_repository" "lambda" {
  name                 = "${var.regional_id}-zoa-lambda"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment == "ephemeral"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.zoa.arn
  }

  tags = merge(local.common_tags, { Name = "${var.regional_id}-zoa-lambda" })
}


# --- Lifecycle policies: keep last 20 images ---

resource "aws_ecr_lifecycle_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}


# --- Cross-account pull policies ---
# Allows MC accounts (via OU path) and Lambda service (for image optimization)

resource "aws_ecr_repository_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOUPull"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Condition = {
          "ForAnyValue:StringLike" = {
            "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
          }
        }
      },
      {
        Sid       = "LambdaCrossAccountRetrieval"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
      },
    ]
  })
}


# --- Mirror images from source registry → ECR (skip if tag already exists) ---

resource "null_resource" "mirror_lambda" {
  triggers = {
    image_tag   = var.zoa_lambda_image_tag
    source_repo = var.zoa_lambda_source_image
    repo        = aws_ecr_repository.lambda.repository_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eo pipefail

      REPO="${aws_ecr_repository.lambda.name}"
      TAG="${var.zoa_lambda_image_tag}"
      SRC="docker://${var.zoa_lambda_source_image}:$TAG"
      DST="docker://${aws_ecr_repository.lambda.repository_url}:$TAG"
      REGION="${data.aws_region.current.id}"

      if aws ecr describe-images --repository-name "$REPO" \
          --image-ids imageTag="$TAG" --region "$REGION" 2>/dev/null | grep -q imageDigest; then
        echo "[zoa] $REPO:$TAG already in ECR, skipping mirror"
        exit 0
      fi

      if ! command -v skopeo &>/dev/null; then
        echo "[zoa] ERROR: skopeo not found in the platform image." >&2
        exit 1
      fi

      echo "[zoa] Mirroring $SRC → $DST"
      skopeo copy --retry-times 3 "$SRC" "$DST" \
        --dest-creds "AWS:$(aws ecr get-login-password --region "$REGION")"

      echo "[zoa] Verifying image exists in ECR after mirror..."
      aws ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TAG" --region "$REGION" > /dev/null
      echo "[zoa] $REPO:$TAG mirrored and verified"
    EOT
  }

  depends_on = [aws_ecr_repository.lambda]
}


data "aws_region" "current" {}
