# =============================================================================
# VPC Module Variables
# =============================================================================

variable "resource_name_base" {
  description = "Base name for all resources (e.g., regional-cluster-x8k2)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of availability zones. If empty, will auto-detect first 3 AZs in the region."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "If specified, must provide at least 2 availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.0.0/18", "10.0.64.0/18", "10.0.128.0/18"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Must provide at least 2 private subnets for high availability."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.private_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.private_subnet_cidrs) <= 3
    )
    error_message = "Number of private subnet CIDRs cannot exceed available availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (used only for NAT gateway)"
  type        = list(string)
  default     = ["10.0.192.0/22", "10.0.196.0/22", "10.0.200.0/22"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 1
    error_message = "Must provide at least 1 public subnet for NAT gateway."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.public_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.public_subnet_cidrs) <= 3
    )
    error_message = "Number of public subnet CIDRs cannot exceed available availability zones."
  }
}

variable "eks_control_plane_subnet_cidrs" {
  description = "CIDR blocks for the dedicated EKS control plane subnets (cluster network interfaces only), one per AZ. Empty places the cluster's interfaces in the private subnets."
  type        = list(string)
  default     = ["10.0.204.0/26", "10.0.204.64/26", "10.0.204.128/26"]

  validation {
    condition     = length(var.eks_control_plane_subnet_cidrs) == 0 || length(var.eks_control_plane_subnet_cidrs) >= 2
    error_message = "EKS needs control plane subnets in at least 2 availability zones."
  }
}

# Ensure private and public subnet counts match
locals {
  # tflint-ignore: terraform_unused_declarations
  subnet_count_validation = length(var.private_subnet_cidrs) == length(var.public_subnet_cidrs) ? true : tobool("Private and public subnet counts must match")
}

# =============================================================================
# Hosted control plane (HCP) slots (management clusters only)
# =============================================================================

variable "hcp_slot_count" {
  description = "Number of hosted control plane (HCP) slots: per-HCP /22 networks of three /24 subnets behind their own NACL. 0 (default) creates none."
  type        = number
  default     = 0

  validation {
    condition     = var.hcp_slot_count >= 0 && var.hcp_slot_count <= 99 && floor(var.hcp_slot_count) == var.hcp_slot_count
    error_message = "hcp_slot_count must be a whole number from 0 to 99 (slot names are two digits)."
  }
}

variable "hcp_slot_cidrs" {
  description = "Secondary VPC CIDRs that hold the hosted control plane slots, one /22 per slot, filled in order. All must have the same prefix length, between /16 and /22."
  type        = list(string)
  default     = ["10.1.0.0/16"]

  validation {
    condition     = alltrue([for c in var.hcp_slot_cidrs : can(cidrhost(c, 0)) && tonumber(split("/", c)[1]) >= 16 && tonumber(split("/", c)[1]) <= 22])
    error_message = "Each HCP slot CIDR must be a valid IPv4 CIDR between /16 and /22."
  }

  validation {
    condition     = length(distinct([for c in var.hcp_slot_cidrs : split("/", c)[1]])) <= 1
    error_message = "All HCP slot CIDRs must have the same prefix length."
  }
}

# Ensure the secondary CIDRs hold every slot.
locals {
  # tflint-ignore: terraform_unused_declarations
  slot_capacity_validation = var.hcp_slot_count <= length(var.hcp_slot_cidrs) * local.slots_per_cidr ? true : tobool("hcp_slot_cidrs don't have room for hcp_slot_count slots (one /22 each)")
}
