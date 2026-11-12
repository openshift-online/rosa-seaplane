# =============================================================================
# Required variables
# =============================================================================

variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

# =============================================================================
# Kubernetes configuration
# =============================================================================

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.cluster_version))
    error_message = "Cluster version must be more modern."
  }
}

# =============================================================================
# VPC inputs (from vpc module)
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes"
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Subnet IDs for the EKS control plane network interfaces. Empty uses private_subnet_ids."
  type        = list(string)
  default     = []
}

variable "cluster_security_group_id" {
  description = "Pre-created security group ID for EKS cluster control plane"
  type        = string
}

variable "vpc_endpoints_security_group_id" {
  description = "Pre-created security group ID for VPC endpoints"
  type        = string
}

# =============================================================================
# Karpenter configuration
# =============================================================================

variable "ami_kms_key_arn" {
  description = "ARN of the Red Hat KMS key used to encrypt RHEL FIPS AMI EBS snapshots. When set, an IAM policy granting kms:CreateGrant and kms:DescribeKey on this key is added to the Karpenter controller role. Leave empty to skip KMS policy creation."
  type        = string
  default     = ""
}

variable "worker_node_ami_id" {
  description = "Custom AMI ID for the Karpenter bootstrap managed node group. Empty (default) uses the EKS-optimized AL2023 AMI (ami_type AL2023_x86_64_STANDARD) with EKS-managed bootstrap. When set, the node group uses ami_type CUSTOM and the launch template supplies nodeadm bootstrap user_data, so the AMI must be nodeadm-compatible (e.g. RHEL/AL2023 for EKS)."
  type        = string
  default     = ""
}

variable "worker_node_root_volume_size" {
  description = "Root EBS volume size (GiB) for the Karpenter bootstrap nodes."
  type        = number
  default     = 50
}


# =============================================================================
# Hosted control plane (HCP) slots (management clusters only)
# =============================================================================

variable "hcp_slot_subnet_arns" {
  description = "Subnet ARNs of each HCP slot, keyed by slot number (vpc module output). Each slot gets its own node role and instance profile, scoped to its subnets. Empty (default) creates none."
  type        = map(list(string))
  default     = {}
}
