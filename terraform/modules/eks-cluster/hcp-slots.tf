# =============================================================================
# Hosted Control Plane (HCP) Slot Node Roles (management clusters)
#
# Each slot gets its own node role so its VPC CNI permissions can be limited
# to its own subnets and interfaces (vpc-cni-iam.tf). Pods can't reach these
# credentials: slot EC2NodeClasses set IMDS hop limit 1.
#
# Slots and their subnets come from the vpc module (hcp_slot_subnet_arns).
# =============================================================================

locals {
  hcp_slot_node_role_name = { for slot, _ in var.hcp_slot_subnet_arns : slot => "${local.cluster_id}-hcp-slot-${slot}-node" }
}

resource "aws_iam_role" "hcp_slot_node" {
  for_each = var.hcp_slot_subnet_arns
  name     = local.hcp_slot_node_role_name[each.key]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, {
    Name                   = local.hcp_slot_node_role_name[each.key]
    "seaplane.io/hcp-slot" = each.key
  })
}

# The platform node role's managed policies, without AmazonEKS_CNI_Policy.
resource "aws_iam_role_policy_attachment" "hcp_slot_node_managed" {
  for_each = merge([
    for slot, _ in var.hcp_slot_subnet_arns : {
      for policy in [
        "AmazonEKSWorkerNodePolicy",
        "AmazonEC2ContainerRegistryPullOnly",
        "AmazonSSMManagedInstanceCore",
      ] : "${slot}-${policy}" => { slot = slot, policy = policy }
    }
  ]...)
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value.policy}"
  role       = aws_iam_role.hcp_slot_node[each.value.slot].name
}

# VPC CNI permissions scoped to the slot's subnets: vpc-cni-iam.tf.

# Referenced by the slot's EC2NodeClass.spec.instanceProfile, so the Karpenter
# controller needs no iam:CreateInstanceProfile.
resource "aws_iam_instance_profile" "hcp_slot_node" {
  for_each = var.hcp_slot_subnet_arns
  name     = local.hcp_slot_node_role_name[each.key]
  role     = aws_iam_role.hcp_slot_node[each.key].name
  tags     = local.common_tags
}

# Lets nodes with the slot role join the cluster (the platform node role gets
# its access entry from the bootstrap managed node group).
resource "aws_eks_access_entry" "hcp_slot_node" {
  for_each      = var.hcp_slot_subnet_arns
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.hcp_slot_node[each.key].arn
  type          = "EC2_LINUX"
  tags          = local.common_tags
}

resource "aws_iam_role_policy" "karpenter_controller_hcp_slot_pass_role" {
  count = length(var.hcp_slot_subnet_arns) > 0 ? 1 : 0
  name  = "hcp-slot-pass-role"
  role  = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "HCPSlotNodePassRole"
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = [for role in aws_iam_role.hcp_slot_node : role.arn]
      Condition = {
        StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
      }
    }]
  })
}
