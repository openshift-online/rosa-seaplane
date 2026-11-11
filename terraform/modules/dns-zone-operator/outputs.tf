# =============================================================================
# DNS Zone Operator Outputs
# =============================================================================

output "role_arn" {
  description = "ARN of the dns-zone-operator role (created in the DNS shard account). MC operators (external-dns, cert-manager) assume it for Route53 access to the zone shards."
  value       = aws_iam_role.dns_zone_operator.arn
}
