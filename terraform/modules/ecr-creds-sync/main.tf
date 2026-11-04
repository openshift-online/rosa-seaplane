# =============================================================================
# ECR Credentials Sync Pod Identity (MC-side)
#
# IAM role and Pod Identity association for the ecr-creds-sync controller
# running in the hypershift namespace on the MC. The controller calls
# ecr:GetAuthorizationToken to mint short-lived ECR tokens and writes them
# as pull-secrets into each HCP namespace.
# =============================================================================

resource "aws_iam_role" "ecr_creds_sync" {
  name        = "${var.management_id}-ecr-creds-sync"
  description = "Pod Identity role for ecr-creds-sync to call ecr:GetAuthorizationToken"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = {
    Name = "${var.management_id}-ecr-creds-sync"
  }
}

resource "aws_iam_role_policy" "ecr_get_auth_token" {
  name = "${var.management_id}-ecr-get-auth-token"
  role = aws_iam_role.ecr_creds_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ECRGetAuthorizationToken"
      Effect   = "Allow"
      Action   = "ecr:GetAuthorizationToken"
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "ecr_creds_sync" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hypershift"
  service_account = "ecr-creds-sync"
  role_arn        = aws_iam_role.ecr_creds_sync.arn

  tags = merge(local.common_tags, {
    Name = "${var.management_id}-ecr-creds-sync-pod-identity"
  })
}
