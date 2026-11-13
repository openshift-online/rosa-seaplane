# =============================================================================
# VPC and Networking Configuration
#
# Creates a fully private networking environment with:
# - Multi-AZ private/public subnets for high availability
# - Per-AZ NAT Gateways for fault-tolerant egress
# - VPC endpoints for AWS service access without internet routing
# =============================================================================

# -----------------------------------------------------------------------------
# VPC and Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.common_tags, { Name = "${var.resource_name_base}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.resource_name_base}-igw" })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                     = "${var.resource_name_base}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                              = "${var.resource_name_base}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${var.resource_name_base}" = "owned"
  })
}

# EKS control plane network interfaces get their own subnets, so worker subnets
# (private subnets, HCP slots) can change without touching the
# cluster's network configuration. No kubernetes.io/cluster or ELB role tags:
# nodes and load balancers are never placed here.
resource "aws_subnet" "eks_control_plane" {
  count             = length(var.eks_control_plane_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.eks_control_plane_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.resource_name_base}-eks-${local.azs[count.index]}"
  })
}

# -----------------------------------------------------------------------------
# NAT Gateways (per-AZ for high availability)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "${var.resource_name_base}-nat-eip-${local.azs[count.index]}"
  })
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
  tags = merge(local.common_tags, {
    Name = "${var.resource_name_base}-nat-gw-${local.azs[count.index]}"
  })
}

# -----------------------------------------------------------------------------
# VPC Endpoints
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = merge(local.common_tags, { Name = "${var.resource_name_base}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = merge(local.common_tags, { Name = "${var.resource_name_base}-dynamodb-endpoint" })
}

locals {
  services = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "logs",
    "ec2",
    "bedrock-runtime",
    "kms",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.services)
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.common_tags, { Name = "${var.resource_name_base}-${each.value}-endpoint" })
}

# -----------------------------------------------------------------------------
# Routing Tables
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "${var.resource_name_base}-public-rt" })
}

resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.resource_name_base}-private-rt-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "eks_control_plane" {
  count          = length(var.eks_control_plane_subnet_cidrs)
  subnet_id      = aws_subnet.eks_control_plane[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
