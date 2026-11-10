# =============================================================================
# OIDC Writer IAM Role
#
# RC-side role that MC operators (hypershift-operator) assume via
# cross-account Pod Identity to write OIDC documents to the regional S3
# bucket. Trust is OU-based so new MC accounts get access automatically.
# Same pattern as dns-zone-operator.
# =============================================================================

resource "aws_iam_role" "oidc_writer" {
  name        = "${var.regional_id}-oidc-writer"
  description = "Cross-account role for MC hypershift-operator to write OIDC documents to the regional S3 bucket"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = split("/", var.mc_ou_path)[0]
        }
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:aws:iam::*:role/*-hypershift-operator"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-oidc-writer"
  })
}

resource "aws_iam_role_policy" "oidc_writer" {
  name = "${var.regional_id}-oidc-writer-s3-kms"
  role = aws_iam_role.oidc_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.oidc.arn,
          "${aws_s3_bucket.oidc.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.oidc.arn
      },
    ]
  })
}

# =============================================================================
# OIDC Signing Key Reader IAM Role
#
# RC-side role that MC External Secrets Operator service accounts assume via
# cross-account Pod Identity to read OIDC signing keys from the RC's Secrets
# Manager. Mirror image of oidc_writer: trust is OU-based so new MC accounts
# get access automatically, but scoped to the ESO role name pattern and
# narrowed to read-only Secrets Manager access.
# =============================================================================

resource "aws_iam_role" "oidc_key_reader" {
  name        = "${var.regional_id}-oidc-key-reader"
  description = "Cross-account role for MC external-secrets-operator to read OIDC signing keys from the regional Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = split("/", var.mc_ou_path)[0]
        }
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.mc_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:aws:iam::*:role/*-external-secrets-operator"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-oidc-key-reader"
  })
}

resource "aws_iam_role_policy" "oidc_key_reader" {
  name = "${var.regional_id}-oidc-key-reader-secrets-kms"
  role = aws_iam_role.oidc_key_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:/seaplane/oidc/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.oidc.arn
      },
    ]
  })
}
