# =============================================================================
# Scoped VPC CNI Permissions for Node Roles
#
# Every node runs the VPC CNI's aws-node with the node's credentials. The
# managed AmazonEKS_CNI_Policy allows network interface changes on every subnet
# in the account, so root on a node (or, on platform nodes where IMDS hop limit
# 2 still applies, a pod) could attach an interface in an HCP slot's subnet,
# past the slot NACL. Each node role therefore gets AmazonEKS_CNI_Policy's
# actions limited to its own subnets, the network interfaces in them and the
# EKS cluster security group:
#
# - platform node role: the private subnets
# - each HCP slot's node role: the slot's subnets, and only instances launched
#   with the slot's instance profile
# =============================================================================

locals {
  ec2_arn_prefix = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"

  # Nodes only carry the EKS cluster security group (EC2NodeClass selector and
  # the bootstrap node group's default), and the CNI copies the primary
  # interface's groups onto the interfaces it creates.
  node_security_group_arn = "${local.ec2_arn_prefix}:security-group/${aws_eks_cluster.main.vpc_config[0].cluster_security_group_id}"

  scoped_cni = merge(
    {
      platform = {
        role    = aws_iam_role.karpenter_node.id
        subnets = [for id in var.private_subnet_ids : "${local.ec2_arn_prefix}:subnet/${id}"]
        # The bootstrap managed node group's instances use an instance profile
        # EKS creates, so platform instances aren't restricted by profile.
        instance_profile = null
      }
    },
    {
      for slot, subnets in var.hcp_slot_subnet_arns : "hcp-slot-${slot}" => {
        role             = aws_iam_role.hcp_slot_node[slot].id
        subnets          = subnets
        instance_profile = aws_iam_instance_profile.hcp_slot_node[slot].arn
      }
    },
  )
}

resource "aws_iam_role_policy" "scoped_cni" {
  #checkov:skip=CKV_AWS_355: ec2:Describe* actions don't support resource-level restrictions; Resource="*" is required.
  for_each = local.scoped_cni
  name     = "vpc-cni"
  role     = each.value.role

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid      = "CreateInOwnSubnets"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterface"
        Resource = concat(each.value.subnets, [local.node_security_group_arn])
      },
      {
        # No ec2:Subnet condition here. AssignPrivateIpAddresses,
        # AttachNetworkInterface and ModifyNetworkInterfaceAttribute don't
        # populate ec2:Subnet in the request context, so an ArnEquals on it
        # evaluates false and denies the CNI's normal IP/ENI operations. The
        # subnet boundary is enforced at creation instead: CreateInOwnSubnets
        # only allows ec2:CreateNetworkInterface in the role's own subnets, so a
        # node can only ever own interfaces there and can't reach another slot's
        # subnet by attaching or re-addressing one.
        Sid    = "OwnNetworkInterfaces"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:CreateTags",
        ]
        Resource = "${local.ec2_arn_prefix}:network-interface/*"
      },
      # Attach, detach and setting an attachment attribute all act on the
      # instance. The CNI calls ModifyNetworkInterfaceAttribute after attaching
      # a secondary ENI (to set the attachment's DeleteOnTermination); AWS
      # evaluates that call against the instance resource, so without it here
      # the ENI is created but never usably attached and the IP pool can't grow
      # past the primary ENI ("no available IP/Prefix addresses").
      merge(
        {
          Sid      = "OwnInstances"
          Effect   = "Allow"
          Action   = ["ec2:AttachNetworkInterface", "ec2:DetachNetworkInterface", "ec2:ModifyNetworkInterfaceAttribute"]
          Resource = "${local.ec2_arn_prefix}:instance/*"
        },
        each.value.instance_profile == null ? {} : {
          Condition = {
            ArnEquals = { "ec2:InstanceProfile" = each.value.instance_profile }
          }
        },
      ),
      {
        # Setting an interface's security groups acts on the groups too: only
        # the cluster security group nodes already carry.
        Sid      = "NodeSecurityGroup"
        Effect   = "Allow"
        Action   = "ec2:ModifyNetworkInterfaceAttribute"
        Resource = local.node_security_group_arn
      },
    ]
  })
}
