# =============================================================================
# EKS Cluster Configuration
#
# Creates a fully private EKS cluster with self-managed Karpenter compute.
# Includes KMS encryption for secrets, proper networking,
# and managed addons for a complete cluster deployment.
# VPC and networking are provided as inputs from the vpc module.
# =============================================================================

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for Audit Log Encryption
#
# Customer-managed KMS key encrypts EKS CloudWatch log data at rest so that
# audit records cannot be read without KMS key authorization. Note: KMS does
# not prevent deletion — log group deletion and retention are controlled by
# IAM permissions (logs:DeleteLogGroup) and the retention_in_days setting.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "cloudwatch_logs" {
  description             = "KMS key for EKS cluster CloudWatch log group encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_id}/cluster"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_id}-cloudwatch-logs"
  })
}

resource "aws_kms_alias" "cloudwatch_logs" {
  name          = "alias/${local.cluster_id}-cloudwatch-logs"
  target_key_id = aws_kms_key.cloudwatch_logs.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Logging
# -----------------------------------------------------------------------------

# Note: setting kms_key_id on an existing log group only encrypts newly ingested
# events. Historical events remain under the previously configured key (or no key).
# For brownfield clusters, export historical logs to S3 before applying this change,
# or document a compliance exception. Do NOT delete/recreate the log group as this
# would discard retained audit logs required by AU-11.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn
  tags              = local.common_tags

  depends_on = [aws_kms_key.cloudwatch_logs]
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------

# The subnets Karpenter launches nodes into. The cluster depends on them so that
# on destroy its provisioner below terminates those nodes and deletes their
# network interfaces before the subnets are deleted. The cluster itself only
# references its control plane subnets.
resource "terraform_data" "node_subnets" {
  input = concat(var.private_subnet_ids, flatten(values(var.hcp_slot_subnet_arns)))
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_id
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version
  tags     = local.common_tags

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  vpc_config {
    # Dedicated subnets for the cluster's network interfaces when provided, so
    # worker subnets can change independently. Updated in place by EKS.
    subnet_ids              = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [var.cluster_security_group_id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_managed,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks_secrets,
    terraform_data.node_subnets,
  ]

  # Karpenter nodes are created outside Terraform by the in-cluster controller.
  # We terminate them directly (rather than draining via NodeClaim deletion)
  # so the VPC CNI never gets a chance to release its ENIs gracefully. We must
  # clean up those orphaned ENIs ourselves or the subnet/VPC teardown will hang.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = fail
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if ! command -v aws >/dev/null 2>&1; then
        echo "ERROR: aws CLI not found -- install awscli to proceed" >&2
        exit 1
      fi
      if ! command -v timeout >/dev/null 2>&1; then
        echo "ERROR: timeout not found -- install coreutils to proceed" >&2
        exit 1
      fi

      CLUSTER_NAME="${self.name}"
      REGION=$(echo "${self.arn}" | cut -d: -f4)

      echo "Terminating Karpenter EC2 instances for cluster: $CLUSTER_NAME"
      INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters \
          "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
          "Name=tag-key,Values=karpenter.sh/nodeclaim" \
          "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

      if [ -z "$INSTANCE_IDS" ]; then
        echo "No Karpenter-managed instances found."
      else
        echo "Terminating: $INSTANCE_IDS"
        aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
        if ! timeout 300 aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS; then
          echo "ERROR: instances did not reach terminated state within 300s: $INSTANCE_IDS" >&2
          exit 1
        fi
        echo "Instances terminated."
      fi

      echo "Waiting for VPC CNI ENIs to be released..."

      # VPC CNI trunk/branch ENIs are cleaned up asynchronously by AWS after
      # instance termination. Poll until they're gone or we can delete them.
      for attempt in $(seq 1 18); do
        ENI_IDS=$(aws ec2 describe-network-interfaces \
          --region "$REGION" \
          --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER_NAME" \
          --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
          --output text)

        if [ -n "$ENI_IDS" ]; then
          echo "Deleting detached ENIs: $ENI_IDS"
          for eni in $ENI_IDS; do
            aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null || true
          done
        fi

        REMAINING=$(aws ec2 describe-network-interfaces \
          --region "$REGION" \
          --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER_NAME" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text)

        if [ -z "$REMAINING" ]; then
          echo "All ENIs cleaned up."
          break
        fi

        echo "Attempt $attempt/18: ENIs still attached, waiting 10s..."
        sleep 10
      done

      if [ -n "$REMAINING" ]; then
        echo "ERROR: ENIs still present after 3 minutes: $REMAINING" >&2
        echo "Delete them manually, then re-run terraform destroy." >&2
        exit 1
      fi
      echo "Done."
    EOT
  }
}

# -----------------------------------------------------------------------------
# EKS Managed Addons
#
# Essential addons for cluster functionality:
# - CoreDNS: cluster DNS resolution
# - metrics-server: pod/node metrics for HPA and kubectl top
# - Pod Identity Agent: AWS IAM integration for workloads (DaemonSet, safe pre-node)
# - AWS Secrets Store CSI Driver Provider: Secret mounting (DaemonSet, safe pre-node)
#
# CoreDNS and metrics-server are declared here so Terraform creates them before
# the ECS bootstrap task runs. The built-in "system" pool provides nodes for them
# to schedule on, so there is no deadlock. Without this declaration, a fresh cluster
# has no coredns/metrics-server addons and the bootstrap wait-addon-active call fails
# with ResourceNotFoundException.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  tags         = local.common_tags
  depends_on   = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"
  # Pinned to work around metrics-server#1868: v0.9.0 corrupts the aggregated
  # /openapi/v2 schema so protobuf requests return 503 (JSON returns 200). That
  # 503s the apiserver's merged openapi for all clients and breaks ArgoCD's
  # cluster-cache sync (gitops-engine loads the v2 schema unconditionally for its
  # GVKParser), leaving every Application stuck "Unknown". v0.8.1-eksbuild.10 is
  # unaffected. Remove this pin once EKS ships an addon built on a fixed
  # metrics-server. https://github.com/kubernetes-sigs/metrics-server/issues/1868
  addon_version = "v0.8.1-eksbuild.10"
  tags          = local.common_tags
  depends_on    = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  tags         = local.common_tags
  depends_on   = [aws_eks_node_group.karpenter_bootstrap]
}

# Fixed-size node group for Karpenter + ArgoCD (system-cluster-critical).
# Karpenter provisions all other nodes.
# -----------------------------------------------------------------------------

resource "aws_launch_template" "karpenter_bootstrap" {
  name_prefix = "${local.cluster_id}-karpenter-bootstrap-"
  tags        = local.common_tags

  # When a custom AMI is pinned, EKS no longer injects node bootstrap, so the
  # launch template must set the image and supply nodeadm user_data itself.
  # Empty (default) leaves both unset and EKS manages the AL2023 AMI + bootstrap.
  image_id = var.worker_node_ami_id != "" ? var.worker_node_ami_id : null

  user_data = var.worker_node_ami_id != "" ? base64encode(templatefile("${path.module}/templates/bootstrap-nodeadm-userdata.tftpl", {
    cluster_name          = aws_eks_cluster.main.name
    api_server_endpoint   = aws_eks_cluster.main.endpoint
    certificate_authority = aws_eks_cluster.main.certificate_authority[0].data
    service_cidr          = aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr
  })) : null

  metadata_options {
    http_tokens = "required"
  }

  # The device_name must match the AMI's root device or EC2 treats this as a new
  # blank volume and requires an explicit size/snapshotId. The AL2023 EKS-optimized
  # AMI roots at /dev/xvda; the pinned RHEL AMI roots at /dev/sda1.
  block_device_mappings {
    device_name = var.worker_node_ami_id != "" ? "/dev/sda1" : "/dev/xvda"
    ebs {
      encrypted   = true
      volume_type = "gp3"
      volume_size = var.worker_node_root_volume_size
    }
  }
}

resource "aws_eks_node_group" "karpenter_bootstrap" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_id}-karpenter-bootstrap"
  node_role_arn   = aws_iam_role.karpenter_node.arn
  subnet_ids      = var.private_subnet_ids

  # CUSTOM required when the launch template pins a non-EKS-optimized AMI (e.g. RHEL);
  # otherwise use the EKS-optimized AL2023 AMI managed by the node group.
  ami_type       = var.worker_node_ami_id != "" ? "CUSTOM" : "AL2023_x86_64_STANDARD"
  instance_types = ["m7i.xlarge"]

  launch_template {
    id      = aws_launch_template.karpenter_bootstrap.id
    version = aws_launch_template.karpenter_bootstrap.latest_version
  }

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  tags = merge(local.common_tags, {
    "karpenter.sh/discovery" = aws_eks_cluster.main.name
  })

  depends_on = [
    aws_iam_role_policy_attachment.karpenter_node_managed,
    aws_iam_role_policy.scoped_cni,
    aws_eks_addon.vpc_cni,
  ]
}

# -----------------------------------------------------------------------------
# Explicit Core Addons (Karpenter mode only)
#
# bootstrap_self_managed_addons = false prevents EKS from auto-installing these.
# Auto Mode clusters receive VPC CNI and kube-proxy from the managed control
# plane; Karpenter clusters must declare them explicitly.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  tags         = local.common_tags

  # Each HCP slot has a /24 per AZ. The default (one warm ENI per
  # node, up to 30 IPs on large instances) would exhaust it with a few nodes;
  # keep about one IP per pod plus a few spare per node instead.
  configuration_values = length(var.hcp_slot_subnet_arns) > 0 ? jsonencode({
    env = {
      WARM_ENI_TARGET   = "0"
      WARM_IP_TARGET    = "2"
      MINIMUM_IP_TARGET = "8"
    }
  }) : null
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
  tags         = local.common_tags

  depends_on = [aws_eks_node_group.karpenter_bootstrap, aws_eks_addon.pod_identity, aws_eks_pod_identity_association.ebs_csi]
}

# AWS Secrets Store CSI Driver Provider (e.g. for kube-applier or service secret mounting)
resource "aws_eks_addon" "aws_secrets_store_csi_driver_provider" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-secrets-store-csi-driver-provider"
  tags         = local.common_tags

  configuration_values = jsonencode({
    secrets-store-csi-driver = {
      syncSecret = {
        enabled = true
      }
    }
  })

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}
