provider "aws" {
  region = var.region

  # FedRAMP IA-07 / SC-13: Use FIPS 140-2 validated endpoints for all AWS API
  # calls from Terraform when operating in US and GovCloud regions where FIPS
  # endpoints are available. Non-US regions (EU, AP, SA, etc.) do not have FIPS
  # endpoints; enabling them there would cause all API calls to fail.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  # Conditionally assume role for cross-account deployment (local dev only)
  # When target_account_id is set, assume OrganizationAccountAccessRole in target account
  # In pipelines, target_account_id is empty - ambient creds are already the target account
  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-regional-${var.regional_id}"
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

# Central account provider for cross-account DNS delegation.
# In pipelines, ambient creds are the target account (after use_mc_account),
# so this provider uses a named profile written by the buildspec script.
# For local dev, central_aws_profile is empty and ambient creds are used.
provider "aws" {
  alias             = "central"
  region            = var.region
  profile           = var.central_aws_profile != "" ? var.central_aws_profile : null
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

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

data "aws_caller_identity" "central" {
  provider = aws.central
}

# Central account providers for ZOA deployment SSM (/zoa/deployments/*).
# Primary + replica regions; CLI defaults to primary with automatic replica failover.
provider "aws" {
  alias             = "central_deployments"
  region            = var.zoa_central_deployments_primary_region
  profile           = var.central_aws_profile != "" ? var.central_aws_profile : null
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.zoa_central_deployments_primary_region)) ? true : false

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

provider "aws" {
  alias             = "central_deployments_replica"
  region            = var.zoa_central_deployments_replica_region
  profile           = var.central_aws_profile != "" ? var.central_aws_profile : null
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.zoa_central_deployments_replica_region)) ? true : false

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

# When PagerDuty is disabled, a dummy token lets the provider initialize
# without PAGERDUTY_TOKEN. When enabled, null falls through to the env var.
provider "pagerduty" {
  token                       = var.enable_pagerduty ? null : "not-configured"
  skip_credentials_validation = true
}



# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # management_clusters entries are "management_id:account_id" (see provision-infra-rc.sh).
  mc_entries     = var.management_clusters != "" ? split(",", var.management_clusters) : []
  mc_account_ids = [for entry in local.mc_entries : element(split(":", entry), 1)]

  # Dedicated read-only Postgres role for ZOA IAM auth. The master user cannot
  # be reused: granting it rds_iam would disable its password auth, which the
  # seaplane-operator and platform-api depend on. This role is provisioned by
  # the ECS bootstrap task (see module.ecs_bootstrap).
  zoa_db_reader_username = "zoa_ro"

  # RDS IAM authentication resource ARN for the ZOA Lambda read role.
  # Format: arn:aws:rds-db:region:account:dbuser:cluster-resource-id/username
  # Allows the zoa_aws_read role to connect as the zoa_ro role via IAM auth.
  seaplane_db_iam_arn = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${module.seaplane_db.cluster_resource_id}/${local.zoa_db_reader_username}"
}

# =============================================================================
# External Secrets Operator — Pod Identity
#
# Grants ESO access to SSM Parameter Store and Secrets Manager so
# ClusterSecretStores can resolve regional secrets and config. Always
# deployed — individual feature modules should NOT create their own ESO
# pod identity associations.
# =============================================================================

resource "aws_iam_role" "external_secrets_operator" {
  name        = "${var.regional_id}-external-secrets-operator"
  description = "IAM role for External Secrets Operator"

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
    Name      = "${var.regional_id}-external-secrets-operator-role"
    function  = "cluster-infra"
    module    = "regional-cluster"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "eso_ssm" {
  name = "${var.regional_id}-eso-ssm"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.regional_id}/*"
    }]
  })
}

resource "aws_iam_role_policy" "eso_secretsmanager" {
  name = "${var.regional_id}-eso-secretsmanager"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.regional_id}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = module.seaplane_db.kms_key_arn
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets_operator" {
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets_operator.arn

  tags = {
    Name      = "${var.regional_id}-external-secrets-operator-pod-identity"
    function  = "cluster-infra"
    module    = "regional-cluster"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# VPC Module
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.regional_id
}

# =============================================================================
# EKS Cluster
# =============================================================================

module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_id                      = var.regional_id
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
# The regional_cluster module above creates a fully private EKS cluster with a
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
  eks_cluster_arn               = module.regional_cluster.cluster_arn
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.regional_id
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch

  thanos_kms_key_arn = module.thanos_infrastructure.kms_key_arn
  loki_kms_key_arn   = module.loki_infrastructure.kms_key_arn

  management_clusters = var.management_clusters

  rc_aws_account_id = var.target_account_id
  redis_endpoint    = var.enable_rate_limit_redis ? "${module.elasticache_valkey[0].endpoint}:${module.elasticache_valkey[0].port}" : ""

  # ZOA read-only IAM DB role provisioning (runs psql during bootstrap).
  # The RC always has seaplane-db, so enable it unconditionally here. This
  # flag is known at plan time and drives the bootstrap IAM policy's count;
  # the DSN secret ARN below is unknown until apply on a greenfield build.
  enable_zoa_db_bootstrap     = true
  seaplane_db_dsn_secret_arn  = module.seaplane_db.dsn_secret_arn
  seaplane_db_kms_key_arn     = module.seaplane_db.kms_key_arn
  seaplane_db_name            = module.seaplane_db.database_name
  seaplane_db_reader_username = local.zoa_db_reader_username
}

# =============================================================================
# Bastion Module (Optional) - depends on VPC + EKS
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.regional_id
  cluster_name              = module.regional_cluster.cluster_name
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}

# =============================================================================
# API Gateway Module - depends on VPC + EKS (needs node_security_group_id)
# =============================================================================

module "api_gateway" {
  source = "../../modules/api-gateway"

  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  regional_id            = var.regional_id
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  # Custom domain (e.g. api.us-east-1.int0.rosa.devshift.net)
  api_domain_name         = var.enable_api_custom_domain && var.environment_domain != null ? "api.${var.deployment_name}.${var.environment_domain}" : null
  regional_hosted_zone_id = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null

  # Method-level throttling and observability
  metrics_enabled        = var.api_metrics_enabled
  logging_level          = var.api_logging_level
  data_trace_enabled     = var.api_data_trace_enabled
  throttling_burst_limit = var.api_throttling_burst_limit
  throttling_rate_limit  = var.api_throttling_rate_limit
}

# =============================================================================
# RHOBS API Gateway (Observability)
#
# Dedicated REST API + ALB for RHOBS traffic, fully isolated from the Platform
# API. Includes its own VPC Link, ALB, and security groups. Only MC accounts
# can invoke this API via resource policy (metrics ingestion).
# =============================================================================

# =============================================================================
# SRE UI ALB (Optional)
#
# Internal (or internet-facing) ALB for SRE tool access. Host-based routing
# to Grafana, ArgoCD, Prometheus, Thanos QFE, and Loki QFE. HTTPS with
# wildcard ACM cert when environment_domain is set.
# =============================================================================

module "sre_ui_alb" {
  count  = var.enable_sre_tools_gateway ? 1 : 0
  source = "../../modules/sre-ui-alb"

  regional_id            = var.regional_id
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = module.vpc.vpc_cidr
  private_subnet_ids     = module.vpc.private_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  regional_hosted_zone_id = var.environment_domain != null ? aws_route53_zone.regional[0].zone_id : null
  deployment_name         = var.deployment_name
  environment_domain      = var.environment_domain

  internal             = !var.enable_sre_public_access
  allowed_source_cidrs = var.sre_allowed_source_cidrs

  oidc_enabled    = var.enable_sre_oidc_auth
  oidc_issuer_url = var.sre_oidc_issuer_url
  oidc_clients = var.enable_sre_oidc_auth ? {
    grafana    = { client_id = var.sre_grafana_oidc_client_id, client_secret = var.sre_grafana_oidc_client_secret }
    argocd     = { client_id = var.sre_argocd_oidc_client_id, client_secret = var.sre_argocd_oidc_client_secret }
    prometheus = { client_id = var.sre_prometheus_oidc_client_id, client_secret = var.sre_prometheus_oidc_client_secret }
    thanos     = { client_id = var.sre_thanos_oidc_client_id, client_secret = var.sre_thanos_oidc_client_secret }
  } : {}

}

module "rhobs_api_gateway" {
  source = "../../modules/rhobs-api-gateway"

  regional_id            = var.regional_id
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name

  # Method-level observability
  metrics_enabled = var.rhobs_apigw_metrics_enabled
}

# =============================================================================
# Regional DNS Zone (Optional)
#
# When environment_domain is set, creates:
# - Regional hosted zone (<region>.<environment_domain>) in the RC account
# - NS delegation records in the environment zone (central account)
# - Initial zone shard (0.<region>.<environment_domain>) for cluster records
# =============================================================================

resource "aws_route53_zone" "regional" {
  count = var.environment_domain != null ? 1 : 0

  name = "${var.deployment_name}.${var.environment_domain}"

  tags = {
    Name     = "${var.deployment_name}.${var.environment_domain}"
    function = "dns"
    module   = "regional-cluster"
  }
}

# Look up the environment zone in the central account so we can create NS
# delegation without owning the zone in this state.
data "aws_route53_zone" "environment" {
  count    = var.environment_domain != null ? 1 : 0
  provider = aws.central

  name         = var.environment_domain
  private_zone = false
}

# NS delegation from the environment zone (central account) to the regional zone
resource "aws_route53_record" "regional_delegation" {
  count    = var.environment_domain != null ? 1 : 0
  provider = aws.central

  zone_id = data.aws_route53_zone.environment[0].zone_id
  name    = "${var.deployment_name}.${var.environment_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.regional[0].name_servers
}

# =============================================================================
# Zone Shards (Optional)
#
# Each shard is a separate Route53 HostedZone under the regional zone,
# providing ~10k records per shard. MC operators (external-dns, cert-manager)
# create cluster records in shards. seaplane-operator assigns clusters to shards.
# =============================================================================

resource "aws_route53_zone" "zone_shard" {
  count = var.environment_domain != null ? var.zone_shard_count : 0

  name = "${count.index}.${var.deployment_name}.${var.environment_domain}"

  tags = {
    Name     = "${count.index}.${var.deployment_name}.${var.environment_domain}"
    Shard    = tostring(count.index)
    function = "dns"
    module   = "regional-cluster"
  }
}

# NS delegation from the regional zone to each zone shard
resource "aws_route53_record" "zone_shard_delegation" {
  count = var.environment_domain != null ? var.zone_shard_count : 0

  zone_id = aws_route53_zone.regional[0].zone_id
  name    = "${count.index}.${var.deployment_name}.${var.environment_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.zone_shard[count.index].name_servers
}

# =============================================================================
# DNS Zone Operator (Cross-Account IAM for MC operators)
# =============================================================================

# OU path is resolved in the buildspec (scripts/buildspec/provision-infra-rc.sh) with
# backward-compatible fallback (new nested path → legacy flat path) and passed via TF_VAR_region_ou_path.
# This avoids terraform hard-failing on ParameterNotFound for ephemeral/integration envs that still use the old path.

module "dns_zone_operator" {
  count  = var.environment_domain != null ? 1 : 0
  source = "../../modules/dns-zone-operator"

  regional_id                = var.regional_id
  regional_hosted_zone_id    = aws_route53_zone.regional[0].zone_id
  zone_shard_hosted_zone_ids = aws_route53_zone.zone_shard[*].zone_id
  region_ou_path             = var.region_ou_path
}

# =============================================================================
# ZOA (Zero Operator Access) Module
# =============================================================================

module "zoa" {
  source = "../../modules/zoa"

  regional_id                  = var.regional_id
  mc_ou_path                   = var.mc_ou_path
  environment                  = var.environment
  dynamodb_deletion_protection = var.zoa_dynamodb_deletion_protection
  zoa_lambda_image_tag         = var.zoa_lambda_image_tag
  zoa_runner_image_tag         = var.zoa_runner_image_tag
  zoa_lambda_source_image      = var.zoa_lambda_source_image
  zoa_runner_source_image      = var.zoa_runner_source_image
}

module "zoa_lambda" {
  source = "../../modules/zoa-lambda"

  cluster_id  = var.regional_id
  target_type = "rc"

  lambda_image_uri = module.zoa.lambda_image_uri
  job_image_uri    = module.zoa.runner_image_uri

  private_subnet_ids        = module.regional_cluster.private_subnet_ids
  cluster_security_group_id = module.regional_cluster.cluster_security_group_id

  eks_cluster_endpoint = module.regional_cluster.cluster_endpoint
  eks_cluster_ca       = module.regional_cluster.cluster_certificate_authority_data
  eks_cluster_name     = module.regional_cluster.cluster_name

  dynamodb_table_name  = module.zoa.table_name
  audit_table_name     = module.zoa.audit_table_name
  artifact_bucket_name = module.zoa.bucket_name
  artifact_bucket_arn  = module.zoa.bucket_arn
  kms_key_arn          = module.zoa.kms_key_arn
  uploader_role_arn    = module.zoa.uploader_role_arn

  seaplane_db_resource_arn = local.seaplane_db_iam_arn
  # RDS endpoint output is the hostname only; append the port so the value is
  # host:port as required by RDS IAM auth token generation (BuildAuthToken).
  seaplane_db_endpoint = "${module.seaplane_db.endpoint}:${module.seaplane_db.port}"
  seaplane_db_name     = module.seaplane_db.database_name
  # Connect as the dedicated read-only IAM role, not the master user.
  seaplane_db_username = local.zoa_db_reader_username

  # Boundary integration — use deployment_name (e.g. us-east-1-eph-xxx), not regional_id.
  sessions_table_name = module.zoa.sessions_table_name
  deployment_name     = var.deployment_name
  targets_ssm_prefix  = "/zoa/targets/${var.deployment_name}"
  vpc_id              = module.regional_cluster.vpc_id
  boundary_image      = var.zoa_boundary_image

  session_idle_timeout_seconds   = var.zoa_boundary_session_idle_timeout_seconds
  session_stale_creating_seconds = var.zoa_boundary_session_stale_creating_seconds

  lambda_api_concurrency    = var.zoa_lambda_api_concurrency
  lambda_worker_concurrency = var.zoa_lambda_worker_concurrency
}

# =============================================================================
# Bedrock account primitives (agreements, budget)
# =============================================================================
# Per-account resources; skip-if-exists for shared pool accounts. Not wired to ZOA.
# Future: call module.bedrock from dedicated per-account Terraform only.

module "bedrock" {
  source      = "../../modules/bedrock"
  environment = var.environment
}

# =============================================================================
# ZOA Access Lambda (Boundary session management — RC only)
# =============================================================================

module "zoa_access" {
  source = "../../modules/zoa-access"

  providers = {
    aws                             = aws
    aws.central_deployments         = aws.central_deployments
    aws.central_deployments_replica = aws.central_deployments_replica
  }

  depends_on = [module.zoa, module.zoa_lambda]

  regional_id = var.regional_id
  image_uri   = module.zoa.lambda_image_uri

  central_account_id                 = data.aws_caller_identity.central.account_id
  trusted_assumer_role_names         = var.zoa_access_trusted_assumer_role_names
  trusted_assumer_role_name_suffixes = var.zoa_access_trusted_assumer_role_name_suffixes

  mc_account_ids = local.mc_account_ids

  sessions_table_name                 = module.zoa.sessions_table_name
  audit_table_name                    = module.zoa.audit_table_name
  targets_ssm_prefix                  = "/zoa/targets/${var.deployment_name}"
  kms_key_arn                         = module.zoa.kms_key_arn
  deployment_name                     = var.deployment_name
  boundary_ecs_cluster_arn            = module.zoa_lambda.boundary_ecs_cluster_arn
  boundary_task_definition_arn_prefix = module.zoa_lambda.boundary_task_definition_arn_prefix
  boundary_ecs_exec_command           = module.zoa_lambda.boundary_ecs_exec_interactive_command
  exec_scoped_role_arn                = module.zoa_lambda.boundary_exec_scoped_role_arn
  lambda_execution_role_arn           = module.zoa_lambda.access_lambda_role_arn
  lambda_execution_role_name          = module.zoa_lambda.access_lambda_role_name

  session_idle_timeout_seconds = var.zoa_boundary_session_idle_timeout_seconds
  session_max_duration_hours   = var.zoa_boundary_session_max_duration_hours

  lambda_access_concurrency = var.zoa_lambda_access_concurrency
}

# =============================================================================
# Seaplane DB (PostgreSQL)
#
# Replaces fleet-db (workerless EKS). Multi-AZ PostgreSQL instance storing
# seaplane CRs in a single `resources` table with jsonb spec/status.
# The DSN is written to Secrets Manager for ESO to sync into the
# seaplane-db-dsn Kubernetes Secret consumed by the operator and platform-api.
# =============================================================================

module "seaplane_db" {
  source = "../../modules/seaplane-db"

  cluster_id         = var.regional_id
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr           = module.vpc.vpc_cidr

  instance_class = var.seaplane_db_instance_class
  engine_version = var.seaplane_db_engine_version

  backup_retention_period      = var.seaplane_db_backup_retention_period
  deletion_protection          = var.seaplane_db_deletion_protection
  skip_final_snapshot          = var.seaplane_db_skip_final_snapshot
  performance_insights_enabled = var.seaplane_db_performance_insights_enabled
  monitoring_interval          = var.seaplane_db_monitoring_interval
}

# =============================================================================
# ElastiCache Valkey — rate limit counters (GCRA)
# =============================================================================

module "elasticache_valkey" {
  count  = var.enable_rate_limit_redis ? 1 : 0
  source = "../../modules/elasticache-valkey"

  cluster_id         = var.regional_id
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  eks_cluster_security_group_id         = module.vpc.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  node_type      = var.valkey_node_type
  engine_version = var.valkey_engine_version
}

# =============================================================================
# Seaplane Operator IAM (Pod Identity)
#
# The seaplane-operator runs on the RC, reads/writes CRs in seaplane-db
# (Postgres via DSN from Secrets Manager), and writes/reads DynamoDB
# desire tables for MC communication.
# =============================================================================

resource "aws_iam_role" "seaplane_operator" {
  name        = "${var.regional_id}-seaplane-operator"
  description = "IAM role for seaplane-operator with DynamoDB access"

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
    Name      = "${var.regional_id}-seaplane-operator-role"
    Component = "seaplane-operator"
    function  = "messaging"
    module    = "regional-cluster"
    ManagedBy = "terraform"
  }
}

resource "aws_eks_pod_identity_association" "seaplane_operator" {
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "seaplane"
  service_account = "seaplane-operator"
  role_arn        = aws_iam_role.seaplane_operator.arn

  tags = {
    Name      = "${var.regional_id}-seaplane-operator-pod-identity"
    Component = "seaplane-operator"
    function  = "messaging"
    module    = "regional-cluster"
    ManagedBy = "terraform"
  }
}

# S3 and KMS access for OIDC infrastructure management
resource "aws_iam_role_policy" "seaplane_operator_oidc" {
  name = "${var.regional_id}-seaplane-operator-oidc"
  role = aws_iam_role.seaplane_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          module.regional_oidc.bucket_arn,
          "${module.regional_oidc.bucket_arn}/*",
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = module.regional_oidc.kms_key_arn
      },
    ]
  })
}

# Secrets Manager access for OIDC private key storage
resource "aws_iam_role_policy" "seaplane_operator_secrets" {
  name = "${var.regional_id}-seaplane-operator-secrets"
  role = aws_iam_role.seaplane_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:DeleteSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:/seaplane/oidc/*"
      },
    ]
  })
}

# STS AssumeRole for reading customer-managed OIDC secrets (unmanaged configs)
resource "aws_iam_role_policy" "seaplane_operator_assume_role" {
  name = "${var.regional_id}-seaplane-operator-assume-role"
  role = aws_iam_role.seaplane_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeCustomerRoles"
        Effect = "Allow"
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
        Resource = "arn:aws:iam::*:role/*"
        Condition = {
          StringEquals = {
            "iam:ResourceTag/seaplane-access" = "true"
          }
        }
      },
    ]
  })
}

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source       = "../../modules/cloudwatch-exporter"
  cluster_name = module.regional_cluster.cluster_name
}

# =============================================================================
# AWS Load Balancer Controller (Pod Identity for self-managed Karpenter clusters)
#
# EKS Auto Mode includes LBC built-in. Self-managed Karpenter clusters must install it
# explicitly to provide the TargetGroupBinding CRD used by platform-api.
# =============================================================================

module "aws_load_balancer_controller" {
  source       = "../../modules/aws-load-balancer-controller"
  cluster_name = module.regional_cluster.cluster_name
}

# =============================================================================
# Regional OIDC Module
#
# Provisions the shared OIDC S3 bucket and CloudFront distribution owned by
# the RC. Management Clusters write to this bucket cross-account.
# =============================================================================

module "regional_oidc" {
  source = "../../modules/regional-oidc"

  regional_id   = var.regional_id
  mc_ou_path    = var.mc_ou_path
  force_destroy = var.environment == "ephemeral"
}

# =============================================================================
# Grafana CloudWatch Logs (Pod Identity for CW Logs datasource)
# =============================================================================

module "grafana_cloudwatch_logs" {
  source       = "../../modules/grafana-cloudwatch-logs"
  mode         = "primary"
  cluster_name = module.regional_cluster.cluster_name
  regional_id  = var.regional_id
}

# =============================================================================
# CloudTrail Module (FedRAMP AU-12)
# =============================================================================

module "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  source = "../../modules/cloudtrail"

  cluster_id  = var.regional_id
  environment = var.environment
}

# =============================================================================
# PagerDuty Service (Optional)
# =============================================================================

module "pagerduty_service" {
  count  = var.enable_pagerduty ? 1 : 0
  source = "../../modules/pagerduty-service"

  regional_id          = var.regional_id
  environment          = var.environment
  region               = var.region
  eph_prefix           = var.eph_prefix
  escalation_policy_id = var.pagerduty_escalation_policy_id
}

# =============================================================================
# SNS Alerting Module (Phase 2 Alert Fan-Out)
# =============================================================================

module "sns_alerting" {
  count  = var.enable_sns_alerting ? 1 : 0
  source = "../../modules/sns-alerting"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name
}

# =============================================================================
# Thanos Infrastructure Module (Observability)
# =============================================================================
module "thanos_infrastructure" {
  source = "../../modules/thanos-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  # Optional: customize retention and namespace
  metrics_retention_days = var.thanos_metrics_retention_days
  thanos_namespace       = var.thanos_namespace
  thanos_service_account = var.thanos_service_account
}

# =============================================================================
# Loki Infrastructure Module (Observability - Logs)
# =============================================================================
module "loki_infrastructure" {
  source = "../../modules/loki-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  logs_retention_days  = var.loki_logs_retention_days
  loki_namespace       = var.loki_namespace
  loki_service_account = var.loki_service_account
}
