provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-management-${var.management_id}"
    }
  }

  default_tags {
    tags = merge(
      {
        app-code      = var.app_code
        service-phase = var.service_phase
        cost-center   = var.cost_center
        environment   = var.environment
      },
      var.eph_prefix != "" ? { ephemeral-prefix = var.eph_prefix } : {}
    )
  }
}

# =============================================================================
# VPC Module
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.management_id
}

# =============================================================================
# EKS Cluster
# =============================================================================

module "management_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_id                      = var.management_id
  vpc_id                          = module.vpc.vpc_id
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id

  worker_node_ami_id           = var.worker_node_ami_id
  worker_node_root_volume_size = var.worker_node_root_volume_size
}

# =============================================================================
# ECS Bootstrap - Installation Mechanism for Fully Private Cluster
#
# The management_cluster module above creates a fully private EKS cluster with a
# karpenter-bootstrap managed node group (2× m7i.xlarge) where Karpenter and
# ArgoCD will run. However, Terraform cannot reach the private cluster API to
# install software via the helm provider.
#
# This ecs_bootstrap module creates ECS Fargate infrastructure that runs in the
# cluster's VPC and can reach the private EKS API. A one-time bootstrap task
# performs `helm install` of ArgoCD onto the bootstrap nodes, then exits. ArgoCD
# then installs Karpenter and everything else via GitOps. Both continue running
# on the managed node group. The ECS infrastructure remains available for future
# audited SRE operations.
#
# See docs/design/fully-private-eks-bootstrap.md for the full architecture.
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.vpc.vpc_id
  private_subnets               = module.vpc.private_subnet_ids
  eks_cluster_arn               = module.management_cluster.cluster_arn
  eks_cluster_name              = module.management_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.management_id
  container_image               = var.container_image
  rc_aws_account_id             = var.regional_aws_account_id

  repository_url    = var.repository_url
  repository_branch = var.repository_branch
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.management_id
  cluster_name              = module.management_cluster.cluster_name
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}

# =============================================================================
# ZOA per-VPC Lambda (direct EKS access for SA impersonation + Job management)
# =============================================================================

module "zoa_lambda" {
  source = "../../modules/zoa-lambda"

  cluster_id  = var.management_id
  target_type = "mc"

  lambda_image_uri = "${var.zoa_lambda_ecr_url}:${var.zoa_lambda_image_tag}"
  job_image_uri    = "${var.zoa_runner_source_image}:${var.zoa_runner_image_tag}"

  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.vpc.cluster_security_group_id

  eks_cluster_endpoint = module.management_cluster.cluster_endpoint
  eks_cluster_ca       = module.management_cluster.cluster_certificate_authority_data
  eks_cluster_name     = module.management_cluster.cluster_name

  dynamodb_table_name  = var.zoa_table_name
  audit_table_name     = var.zoa_audit_table_name
  artifact_bucket_name = try(split(":", var.zoa_outputs_bucket_arn)[5], "")
  artifact_bucket_arn  = var.zoa_outputs_bucket_arn
  kms_key_arn          = var.zoa_kms_key_arn
  uploader_role_arn    = var.zoa_uploader_role_arn
  data_access_role_arn = var.zoa_data_access_role_arn

  sessions_table_name    = var.zoa_sessions_table_name
  deployment_name        = var.zoa_deployment_name
  vpc_id                 = module.vpc.vpc_id
  boundary_image         = var.zoa_boundary_image
  access_lambda_role_arn = var.zoa_access_lambda_role_arn

  session_idle_timeout_seconds   = var.zoa_boundary_session_idle_timeout_seconds
  session_stale_creating_seconds = var.zoa_boundary_session_stale_creating_seconds

  lambda_api_concurrency    = var.zoa_lambda_api_concurrency
  lambda_worker_concurrency = var.zoa_lambda_worker_concurrency
}

# =============================================================================
# Bedrock account primitives (agreements, budget)
# =============================================================================

module "bedrock" {
  source      = "../../modules/bedrock"
  environment = var.environment
}

# =============================================================================
# DNS Pod Identity (cross-account Route53 access for external-dns + cert-manager)
# =============================================================================

module "dns_pod_identity" {
  source = "../../modules/dns-pod-identity"

  management_id              = var.management_id
  eks_cluster_name           = module.management_cluster.cluster_name
  dns_zone_operator_role_arn = var.dns_zone_operator_role_arn
}

# =============================================================================
# ECR Credentials Sync Pod Identity
# =============================================================================

module "ecr_creds_sync" {
  count  = var.enable_ecr_creds_sync ? 1 : 0
  source = "../../modules/ecr-creds-sync"

  management_id    = var.management_id
  eks_cluster_name = module.management_cluster.cluster_name
}

# =============================================================================
# HyperShift OIDC (Private S3 + CloudFront + Pod Identity)
# =============================================================================

module "hypershift_oidc" {
  source = "../../modules/hypershift-oidc"

  cluster_id       = var.management_id
  eks_cluster_name = module.management_cluster.cluster_name

  oidc_bucket_name         = var.oidc_bucket_name
  oidc_bucket_arn          = var.oidc_bucket_arn
  oidc_bucket_region       = var.oidc_bucket_region
  oidc_writer_role_arn     = var.oidc_writer_role_arn
  oidc_key_reader_role_arn = var.oidc_key_reader_role_arn
  oidc_cloudfront_domain   = var.oidc_cloudfront_domain
}

# =============================================================================
# Prometheus Remote Write (MC -> RC metrics forwarding via API Gateway)
# =============================================================================

module "prometheus_remote_write" {
  source = "../../modules/prometheus-remote-write"

  management_id           = var.management_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name
}

# =============================================================================
# Loki Log Forwarder (MC -> RC log forwarding via API Gateway)
# =============================================================================

module "loki_log_forwarder" {
  source = "../../modules/loki-log-forwarder"

  management_id           = var.management_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name
}

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source       = "../../modules/cloudwatch-exporter"
  cluster_name = module.management_cluster.cluster_name
}

# =============================================================================
# Grafana CloudWatch Logs Reader (cross-account role for RC Grafana)
# =============================================================================

module "grafana_cloudwatch_logs" {
  source                  = "../../modules/grafana-cloudwatch-logs"
  mode                    = "reader"
  cluster_name            = module.management_cluster.cluster_name
  regional_id             = var.management_id
  grafana_role_account_id = var.regional_aws_account_id
}

# =============================================================================
# kube-applier (DynamoDB-backed GitOps controller)
# =============================================================================

module "kube_applier" {
  source = "../../modules/kube-applier"

  management_id     = var.management_id
  eks_cluster_name  = module.management_cluster.cluster_name
  rc_aws_account_id = var.regional_aws_account_id
  aws_region        = var.region
}
