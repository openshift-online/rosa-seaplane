# =============================================================================
# VPC Module Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "eks_control_plane_subnet_ids" {
  description = "IDs of the dedicated EKS control plane subnets; falls back to the private subnets when none are configured"
  value       = length(aws_subnet.eks_control_plane) > 0 ? aws_subnet.eks_control_plane[*].id : aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways"
  value       = aws_nat_gateway.main[*].id
}

output "cluster_security_group_id" {
  description = "Security group ID for EKS cluster control plane"
  value       = aws_security_group.eks_cluster.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "availability_zones" {
  description = "Resolved availability zones used for subnet placement"
  value       = local.azs
}

output "hcp_slot_subnet_arns" {
  description = "Subnet ARNs of each HCP slot, keyed by slot number (\"01\", \"02\", ...)"
  value = {
    for slot in keys(local.slot_cidrs) : slot => [
      for key, subnet in local.slot_subnets : aws_subnet.hcp_slot[key].arn if subnet.slot == slot
    ]
  }
}

output "hcp_slot_cidrs" {
  description = "CIDR of each HCP slot, keyed by slot number"
  value       = local.slot_cidrs
}
