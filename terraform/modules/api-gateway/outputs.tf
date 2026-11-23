# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# API Gateway
# -----------------------------------------------------------------------------

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "api_gateway_arn" {
  description = "API Gateway REST API ARN"
  value       = aws_api_gateway_rest_api.main.arn
}

output "invoke_url" {
  description = "API Gateway invoke URL (use this for testing)"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "stage_name" {
  description = "API Gateway stage name"
  value       = aws_api_gateway_stage.main.stage_name
}

# -----------------------------------------------------------------------------
# VPC Link
# -----------------------------------------------------------------------------

output "vpc_link_id" {
  description = "VPC Link ID"
  value       = aws_apigatewayv2_vpc_link.main.id
}

output "vpc_link_arn" {
  description = "VPC Link ARN"
  value       = aws_apigatewayv2_vpc_link.main.arn
}

# -----------------------------------------------------------------------------
# ALB
# -----------------------------------------------------------------------------

output "alb_arn" {
  description = "Internal ALB ARN"
  value       = aws_lb.platform.arn
}

output "alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = aws_lb.platform.dns_name
}

output "target_group_arn" {
  description = "Target group ARN for TargetGroupBinding"
  value       = aws_lb_target_group.platform.arn
}


# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

output "alb_security_group_id" {
  description = "ALB security group ID (add ingress rules for additional sources if needed)"
  value       = aws_security_group.alb.id
}

output "vpc_link_security_group_id" {
  description = "VPC Link security group ID"
  value       = aws_security_group.vpc_link.id
}

# -----------------------------------------------------------------------------
# Helper Commands
# -----------------------------------------------------------------------------

output "test_command" {
  description = "awscurl command to test the API"
  value       = <<-EOT
    awscurl --service execute-api --region ${data.aws_region.current.id} \
      ${aws_api_gateway_stage.main.invoke_url}/api/v0/live
  EOT
}

# -----------------------------------------------------------------------------
# Custom Domain (only populated when api_domain_name is set)
# -----------------------------------------------------------------------------

output "api_domain_name" {
  description = "Custom domain name for the API (e.g. api.us-east-1.int0.rosa.devshift.org)"
  value       = var.api_domain_name != null ? aws_api_gateway_domain_name.api[0].domain_name : null
}

output "api_domain_regional_domain_name" {
  description = "API Gateway regional domain name — target for DNS alias/CNAME (e.g. d-abc123.execute-api.us-east-1.amazonaws.com)"
  value       = var.api_domain_name != null ? aws_api_gateway_domain_name.api[0].regional_domain_name : null
}

output "api_domain_regional_zone_id" {
  description = "API Gateway regional hosted zone ID for Route53 alias records"
  value       = var.api_domain_name != null ? aws_api_gateway_domain_name.api[0].regional_zone_id : null
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for the API custom domain"
  value       = var.api_domain_name != null ? aws_acm_certificate.api[0].arn : null
}

