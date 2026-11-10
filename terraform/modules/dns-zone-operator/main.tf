# =============================================================================
# DNS Zone Operator IAM Role
#
# RC-side role that MC operators (external-dns, cert-manager) assume via
# cross-account Pod Identity to create records in zone shards. Trust is
# OU-based so new MC accounts get access automatically.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      function = "dns"
      module   = "dns-zone-operator"
    }
  )
}

resource "aws_iam_role" "dns_zone_operator" {
  name        = "${var.regional_id}-dns-zone-operator"
  description = "Cross-account role for MC operators (external-dns, cert-manager) to manage DNS records in zone shards"

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
          "aws:PrincipalOrgID" = split("/", var.region_ou_path)[0]
        }
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.region_ou_path}*"
        }
        StringLike = {
          "aws:PrincipalArn" = "arn:aws:iam::*:role/*-dns-operator"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-dns-zone-operator"
  })
}

resource "aws_iam_role_policy" "dns_zone_operator" {
  name = "${var.regional_id}-dns-zone-operator-route53"
  role = aws_iam_role.dns_zone_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = [for id in var.zone_shard_hosted_zone_ids : "arn:aws:route53:::hostedzone/${id}"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:GetChange"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["route53:ListResourceRecordSets"]
        Resource = concat(
          var.regional_hosted_zone_id != null ? ["arn:aws:route53:::hostedzone/${var.regional_hosted_zone_id}"] : [],
          [for id in var.zone_shard_hosted_zone_ids : "arn:aws:route53:::hostedzone/${id}"]
        )
      }
    ]
  })
}
