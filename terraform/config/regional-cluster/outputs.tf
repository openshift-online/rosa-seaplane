# =============================================================================
# Infrastructure Outputs for Bootstrap Configuration
# =============================================================================

# Cluster identification
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.regional_cluster.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.regional_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.regional_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for kubectl"
  value       = module.regional_cluster.cluster_certificate_authority_data
  sensitive   = true
}

# Networking
output "vpc_id" {
  description = "VPC ID where cluster is deployed"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs where worker nodes are deployed"
  value       = module.vpc.private_subnet_ids
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.vpc.cluster_security_group_id
}

output "seaplane_db_security_group_id" {
  description = "Seaplane DB RDS security group ID"
  value       = module.seaplane_db.security_group_id
}

output "node_security_group_id" {
  description = "EKS node/pod security group ID (Auto Mode primary SG)"
  value       = module.regional_cluster.node_security_group_id
}

# =============================================================================
# ECS Bootstrap Outputs for External Script Usage
# =============================================================================

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_name
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN for bootstrap execution"
  value       = module.ecs_bootstrap.task_definition_arn
}

output "bootstrap_log_group_name" {
  description = "CloudWatch log group name for bootstrap operations"
  value       = module.ecs_bootstrap.log_group_name
}

output "bootstrap_security_group_id" {
  description = "Security group ID for bootstrap ECS tasks"
  value       = module.ecs_bootstrap.bootstrap_security_group_id
}

# =============================================================================
# ArgoCD Bootstrap Configuration Outputs
# =============================================================================

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = module.ecs_bootstrap.repository_url
}

output "repository_branch" {
  description = "Git branch for cluster configuration"
  value       = module.ecs_bootstrap.repository_branch
}

# =============================================================================
# Bastion Outputs (only available when enable_bastion = true)
# =============================================================================

output "bastion_ecs_cluster_name" {
  description = "ECS cluster name for bastion tasks"
  value       = var.enable_bastion ? module.bastion[0].ecs_cluster_name : null
}

output "bastion_log_group_name" {
  description = "CloudWatch log group name for bastion logs"
  value       = var.enable_bastion ? module.bastion[0].log_group_name : null
}

output "bastion_run_task_command" {
  description = "AWS CLI command to start a bastion task"
  value       = var.enable_bastion ? module.bastion[0].run_task_command : null
}

output "bastion_exec_command_template" {
  description = "AWS CLI command template to connect to a running bastion (replace <TASK_ID>)"
  value       = var.enable_bastion ? module.bastion[0].exec_command_template : null
}

output "bastion_ssm_port_forward_template" {
  description = "AWS CLI command template for SSM port forwarding (replace <TASK_ID> and <RUNTIME_ID>)"
  value       = var.enable_bastion ? module.bastion[0].ssm_port_forward_template : null
}

output "log_collector_task_family" {
  description = "Family name of the log-collector task definition"
  value       = var.enable_bastion ? module.bastion[0].log_collector_task_family : null
}

# =============================================================================
# API Gateway Outputs
# =============================================================================

output "api_gateway_invoke_url" {
  description = "API Gateway invoke URL for testing"
  value       = module.api_gateway.invoke_url
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = module.api_gateway.api_gateway_id
}

output "api_target_group_arn" {
  description = "Target group ARN for TargetGroupBinding in Kubernetes"
  value       = module.api_gateway.target_group_arn
}

output "thanos_target_group_arn" {
  description = "Target group ARN for Thanos Receive TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_receive_target_group_arn
}

output "thanos_query_target_group_arn" {
  description = "Target group ARN for Thanos Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_query_target_group_arn
}

output "rhobs_api_url" {
  description = "RHOBS API Gateway invoke URL (used for both MC remote_write and Thanos Query)"
  value       = module.rhobs_api_gateway.invoke_url
}

output "api_alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = module.api_gateway.alb_dns_name
}

output "api_alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.api_gateway.alb_security_group_id
}

output "api_test_command" {
  description = "awscurl command to test the API"
  value       = module.api_gateway.test_command
}

# =============================================================================
# DNS Outputs
# =============================================================================

output "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional domain (e.g. us-east-1.int0.rosa.devshift.net)"
  value       = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null
}

output "regional_domain" {
  description = "Regional domain name (e.g. us-east-1.int0.rosa.devshift.net)"
  value       = var.environment_domain != null ? "${var.region}.${var.environment_domain}" : null
}

output "regional_name_servers" {
  description = "NS records for the regional zone"
  value       = var.environment_domain != null ? aws_route53_zone.regional[0].name_servers : null
}


output "dns_zone_operator_role_arn" {
  description = "ARN of the dns-zone-operator role the MC operators (external-dns, cert-manager) assume for Route53 access. Created in the DNS shard account when configured, else the RC account. Consumed by the MC buildspec (same pattern as the zoa_* role ARNs)."
  value       = var.environment_domain != null ? module.dns_zone_operator[0].role_arn : null
}

output "api_domain_name" {
  description = "Custom domain name for the API (e.g. api.us-east-1.int0.rosa.devshift.net)"
  value       = module.api_gateway.api_domain_name
}

output "api_domain_regional_domain_name" {
  description = "API Gateway regional domain name — target for DNS alias/CNAME"
  value       = module.api_gateway.api_domain_regional_domain_name
}

# =============================================================================
# Seaplane Operator Outputs
# =============================================================================

output "seaplane_operator_role_arn" {
  description = "IAM role ARN for seaplane-operator (Pod Identity)"
  value       = aws_iam_role.seaplane_operator.arn
}

output "seaplane_db_endpoint" {
  description = "Seaplane DB RDS endpoint (host:port)"
  value       = module.seaplane_db.endpoint
}

output "seaplane_db_dsn_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the PostgreSQL DSN"
  value       = module.seaplane_db.dsn_secret_arn
}

output "seaplane_db_dsn_secret_name" {
  description = "Name of the Secrets Manager secret containing the PostgreSQL DSN"
  value       = module.seaplane_db.dsn_secret_name
}

# ElastiCache Valkey
output "seaplane_redis_endpoint" {
  description = "ElastiCache Valkey endpoint for rate limiting (null if disabled)"
  value       = var.enable_rate_limit_redis ? module.elasticache_valkey[0].endpoint : null
}

output "seaplane_redis_port" {
  description = "ElastiCache Valkey port (null if disabled)"
  value       = var.enable_rate_limit_redis ? module.elasticache_valkey[0].port : null
}

# =============================================================================
# CloudWatch Exporter Outputs
# =============================================================================

output "cloudwatch_exporter_role_arn" {
  description = "IAM role ARN for CloudWatch Exporter (Pod Identity)"
  value       = module.cloudwatch_exporter.role_arn
}

# =============================================================================
# Regional OIDC Outputs
# =============================================================================

output "oidc_cloudfront_domain" {
  description = "CloudFront domain for the regional OIDC issuer URL (prefix with https://)"
  value       = module.regional_oidc.cloudfront_domain_name
}

output "oidc_bucket_name" {
  description = "S3 bucket name for regional OIDC discovery documents"
  value       = module.regional_oidc.bucket_name
}

output "oidc_bucket_arn" {
  description = "S3 bucket ARN for regional OIDC discovery documents"
  value       = module.regional_oidc.bucket_arn
}

output "oidc_bucket_region" {
  description = "AWS region of the regional OIDC S3 bucket"
  value       = module.regional_oidc.bucket_region
}

output "oidc_writer_role_arn" {
  description = "ARN of the RC-side oidc-writer IAM role (MC operators assume this for OIDC S3+KMS access)"
  value       = module.regional_oidc.oidc_writer_role_arn
}

# =============================================================================
# Thanos Infrastructure Outputs
# =============================================================================
output "thanos_helm_values" {
  description = "Helm values for Thanos Receiver chart (use with -f flag)"
  value       = module.thanos_infrastructure.helm_values
}

# =============================================================================
# Loki Infrastructure Outputs
# =============================================================================

output "loki_kms_key_arn" {
  description = "KMS key ARN for Loki S3 SSE-KMS encryption"
  value       = module.loki_infrastructure.kms_key_arn
}

output "loki_distributor_target_group_arn" {
  description = "Target group ARN for Loki Distributor TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_distributor_target_group_arn
}

output "loki_query_frontend_target_group_arn" {
  description = "Target group ARN for Loki Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_query_frontend_target_group_arn
}

# =============================================================================
# ZOA Outputs
# =============================================================================

# =============================================================================
# SRE UI ALB Outputs
# =============================================================================

output "sre_grafana_target_group_arn" {
  description = "ARN of the Grafana SRE ALB target group"
  value       = try(module.sre_ui_alb[0].grafana_target_group_arn, "")
}

output "sre_argocd_target_group_arn" {
  description = "ARN of the ArgoCD SRE ALB target group"
  value       = try(module.sre_ui_alb[0].argocd_target_group_arn, "")
}

output "sre_prometheus_target_group_arn" {
  description = "ARN of the Prometheus SRE ALB target group"
  value       = try(module.sre_ui_alb[0].prometheus_target_group_arn, "")
}

output "sre_thanos_target_group_arn" {
  description = "ARN of the Thanos Query Frontend SRE ALB target group"
  value       = try(module.sre_ui_alb[0].thanos_target_group_arn, "")
}

output "sre_alb_dns_name" {
  description = "DNS name of the SRE UI ALB"
  value       = try(module.sre_ui_alb[0].alb_dns_name, "")
}

output "sre_domain" {
  description = "SRE base domain (e.g. sre.us-east-1.int0.rosa.devshift.net)"
  value       = try(module.sre_ui_alb[0].sre_domain, "")
}

output "zoa_table_name" {
  description = "DynamoDB table name for ZOA executions"
  value       = module.zoa.table_name
}

output "zoa_audit_table_name" {
  description = "DynamoDB table name for ZOA audit log"
  value       = module.zoa.audit_table_name
}

output "zoa_sessions_table_name" {
  description = "DynamoDB table name for ZOA boundary sessions (single table in RC, all clusters)"
  value       = module.zoa.sessions_table_name
}

output "zoa_bucket_name" {
  description = "S3 bucket name for ZOA outputs"
  value       = module.zoa.bucket_name
}

output "zoa_bucket_arn" {
  description = "S3 bucket ARN for ZOA outputs (used by MC Pod Identity)"
  value       = module.zoa.bucket_arn
}

output "zoa_kms_key_arn" {
  description = "KMS key ARN for ZOA encryption (used by MC Pod Identity for S3 SSE-KMS)"
  value       = module.zoa.kms_key_arn
}

output "zoa_uploader_role_arn" {
  description = "ARN of the ZOA uploader role (MC Lambdas assume this for scoped S3 creds)"
  value       = module.zoa.uploader_role_arn
}

output "zoa_data_access_role_arn" {
  description = "ARN of the ZOA data-access role (MC Lambdas assume this for cross-account DynamoDB+S3)"
  value       = module.zoa.data_access_role_arn
}

output "zoa_lambda_ecr_url" {
  description = "ECR repository URL for ZOA Lambda (MC appends tag for cross-account pull)"
  value       = module.zoa.lambda_ecr_url
}

output "zoa_access_lambda_role_arn" {
  description = "ARN of the ZOA Access Lambda execution role (MC boundary IAM trusts this for cross-account ECS)"
  value       = module.zoa_lambda.access_lambda_role_arn
}

output "zoa_api_function_url" {
  description = "Function URL for the ZOA API Lambda (used by ZOA boundary tasks and CLI)"
  value       = module.zoa_lambda.api_function_url
}

output "deployment_name" {
  description = "Logical deployment name (ZOA Access/SSM discovery, DNS). Same value passed to module.zoa_access."
  value       = var.deployment_name
}
