# =============================================================================
# SRE UI ALB Outputs
# =============================================================================

output "grafana_target_group_arn" {
  description = "ARN of the Grafana ALB target group"
  value       = aws_lb_target_group.services["grafana"].arn
}

output "argocd_target_group_arn" {
  description = "ARN of the ArgoCD ALB target group"
  value       = aws_lb_target_group.services["argocd"].arn
}

output "prometheus_target_group_arn" {
  description = "ARN of the Prometheus ALB target group"
  value       = aws_lb_target_group.services["prometheus"].arn
}

output "thanos_target_group_arn" {
  description = "ARN of the Thanos Query Frontend ALB target group"
  value       = aws_lb_target_group.services["thanos"].arn
}

output "alb_dns_name" {
  description = "DNS name of the SRE UI ALB"
  value       = aws_lb.sre.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the SRE UI ALB (for Route53 alias records)"
  value       = aws_lb.sre.zone_id
}

output "sre_domain" {
  description = "Base SRE domain (e.g. sre.us-east-1.int0.rosa.devshift.org). Empty when environment_domain is not set."
  value       = local.has_domain ? local.sre_domain : ""
}
