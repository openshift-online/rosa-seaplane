# =============================================================================
# Hosted Control Plane (HCP) Slots (management clusters)
#
# A slot is the network for one hosted control plane's nodes: an aligned /22
# from a secondary VPC CIDR holding one /24 subnet per AZ (the fourth /24 stays
# unused so the slot is one CIDR block in NACL rules), behind its own NACL.
# The NACL denies every other slot and the rest of the primary CIDR, so one
# HCP's nodes and pods (VPC CNI pod IPs come from the node's subnet) can't
# reach another HCP's.
#
# Karpenter finds a slot's subnets by the seaplane.io/hcp-slot and
# seaplane.io/management-cluster tags. They deliberately don't carry the
# kubernetes.io/cluster/<name> tag, so platform nodes and load balancers are
# never placed in them.
#
# The EKS cluster depends on these subnets (eks-cluster terraform_data.node_subnets),
# so on destroy its provisioner terminates Karpenter instances before they go.
# =============================================================================

locals {
  slot_count = var.hcp_slot_count

  # Slots are numbered from 1 (0 means "no slot" in the Seaplane Operator's
  # Placement API). Slot N is the N-th /22 across the secondary CIDRs (64 per /16).
  slot_cidrs = {
    for i in range(local.slot_count) : format("%02d", i + 1) => cidrsubnet(
      var.hcp_slot_cidrs[floor(i / local.slots_per_cidr)], 22 - local.slot_cidr_prefix, i % local.slots_per_cidr
    )
  }
  slot_cidr_prefix = local.slot_count > 0 ? tonumber(split("/", var.hcp_slot_cidrs[0])[1]) : 16
  slots_per_cidr   = pow(2, 22 - local.slot_cidr_prefix)

  # One /24 per AZ in each slot.
  slot_subnets = merge([
    for slot, cidr in local.slot_cidrs : {
      for az_index, az in local.azs : "${slot}-${az}" => {
        slot     = slot
        az       = az
        az_index = az_index
        cidr     = cidrsubnet(cidr, 2, az_index)
      }
    }
  ]...)

  # Slot NACL, the same for ingress and egress (see aws_network_acl below).
  # Rule numbers leave room per group.
  slot_nacl_allow_cidrs = concat(
    [for i, cidr in var.private_subnet_cidrs : { rule = 110 + i, cidr = cidr }],           # EKS API, CoreDNS, monitoring, internal NLBs, endpoints
    [for i, cidr in var.public_subnet_cidrs : { rule = 120 + i, cidr = cidr }],            # NAT, internet-facing NLBs and their health checks
    [for i, cidr in var.eks_control_plane_subnet_cidrs : { rule = 130 + i, cidr = cidr }], # EKS API server network interfaces
  )
  slot_nacl_deny_cidrs = concat(
    [{ rule = 200, cidr = var.vpc_cidr }],                                 # the rest of the primary CIDR
    [for i, cidr in var.hcp_slot_cidrs : { rule = 210 + i, cidr = cidr }], # every other slot
  )
  slot_nacl_rules = {
    for slot, cidr in local.slot_cidrs : slot => concat(
      [{ rule = 100, action = "allow", cidr = cidr }], # the HCP's own nodes and pods
      [for r in local.slot_nacl_allow_cidrs : { rule = r.rule, action = "allow", cidr = r.cidr }],
      [for r in local.slot_nacl_deny_cidrs : { rule = r.rule, action = "deny", cidr = r.cidr }],
      # Internet through NAT, and NLB clients (instance targets see client IPs).
      [{ rule = 300, action = "allow", cidr = "0.0.0.0/0" }],
    )
  }
}

resource "aws_vpc_ipv4_cidr_block_association" "hcp_slots" {
  for_each   = local.slot_count > 0 ? toset(var.hcp_slot_cidrs) : toset([])
  vpc_id     = aws_vpc.main.id
  cidr_block = each.value
}

resource "aws_subnet" "hcp_slot" {
  for_each          = local.slot_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.common_tags, {
    Name                             = "${var.resource_name_base}-hcp-slot-${each.value.slot}-${each.value.az}"
    "seaplane.io/management-cluster" = var.resource_name_base
    "seaplane.io/hcp-slot"           = each.value.slot
  })

  depends_on = [aws_vpc_ipv4_cidr_block_association.hcp_slots]
}

# Same per-AZ NAT egress as the private subnets.
resource "aws_route_table_association" "hcp_slot" {
  for_each       = local.slot_subnets
  subnet_id      = aws_subnet.hcp_slot[each.key].id
  route_table_id = aws_route_table.private[each.value.az_index].id
}

# Rules are inline: one resource per slot instead of one per rule.
resource "aws_network_acl" "hcp_slot" {
  for_each = local.slot_cidrs
  vpc_id   = aws_vpc.main.id
  subnet_ids = [
    for key, subnet in local.slot_subnets : aws_subnet.hcp_slot[key].id if subnet.slot == each.key
  ]

  dynamic "ingress" {
    for_each = local.slot_nacl_rules[each.key]
    content {
      rule_no    = ingress.value.rule
      action     = ingress.value.action
      cidr_block = ingress.value.cidr
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = local.slot_nacl_rules[each.key]
    content {
      rule_no    = egress.value.rule
      action     = egress.value.action
      cidr_block = egress.value.cidr
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
    }
  }

  tags = merge(local.common_tags, {
    Name                   = "${var.resource_name_base}-hcp-slot-${each.key}"
    "seaplane.io/hcp-slot" = each.key
  })
}

# Slot nodes reach the EKS API and the AWS interface endpoints by CIDR.
resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https_hcp_slots" {
  for_each          = local.slot_count > 0 ? toset(var.hcp_slot_cidrs) : toset([])
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "Allow HTTPS from HCP slots for AWS service access"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
  tags              = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "cluster_https_hcp_slots" {
  for_each          = local.slot_count > 0 ? toset(var.hcp_slot_cidrs) : toset([])
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow HCP slots to communicate with API Server"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
  tags              = local.common_tags
}
