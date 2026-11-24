###############################################################################
# modules/vpc
#
# A tiered, three-AZ VPC used for BOTH hub (central API) and spoke (regional)
# VPCs. The important property for this design is the "interconnect" tier:
# it is the only tier whose route tables will ever carry routes to a peered
# VPC, so the data tier is unreachable across peering even if a security
# group is misconfigured (no route back = no session).
###############################################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  subnets = merge([
    for tier, cfg in var.subnet_tiers : {
      for i, az in var.azs : "${tier}-${az}" => {
        tier   = tier
        az     = az
        public = cfg.public
        cidr   = cidrsubnet(var.cidr_block, cfg.newbits, cfg.netnum_base + i)
      }
    }
  ]...)

  public_tiers    = sort([for t, c in var.subnet_tiers : t if c.public])
  private_tiers   = sort([for t, c in var.subnet_tiers : t if !c.public])
  public_subnets  = { for k, s in local.subnets : k => s if s.public }
  private_subnets = { for k, s in local.subnets : k => s if !s.public }

  nat_azs = (
    var.nat_gateway_mode == "per_az" ? var.azs :
    var.nat_gateway_mode == "single" ? [var.azs[0]] : []
  )

  # Private subnets that get a default route to a NAT gateway.
  nat_routed_subnets = {
    for k, s in local.private_subnets : k => s
    if var.nat_gateway_mode != "none" && contains(var.nat_egress_tiers, s.tier)
  }

  flow_log_group_name = "/vpc/flow-logs/${var.name}"

  tags = merge(var.tags, { ManagedBy = "terraform", Module = "vpc" })
}

# -----------------------------------------------------------------------------
# VPC + default SG lockdown (CIS 5.4: default SG must allow nothing)
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  # No ingress/egress blocks => all rules removed.
  tags = merge(local.tags, { Name = "${var.name}-default-DO-NOT-USE" })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false # nothing gets a public IP implicitly, even in public tiers

  tags = merge(local.tags, {
    Name = "${var.name}-${each.key}"
    Tier = each.value.tier
  })
}

# -----------------------------------------------------------------------------
# Public routing (only if a public tier exists)
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  count  = length(local.public_subnets) > 0 ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}

resource "aws_route_table" "public" {
  count  = length(local.public_subnets) > 0 ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public", Tier = "public" })
}

resource "aws_route" "public_internet" {
  count                  = length(local.public_subnets) > 0 ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each       = local.public_subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public[0].id
}

# -----------------------------------------------------------------------------
# NAT (one per AZ by default so an AZ failure never takes out egress elsewhere)
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this["${local.public_tiers[0]}-${each.key}"].id
  tags          = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })

  lifecycle {
    precondition {
      condition     = length(local.public_tiers) > 0
      error_message = "NAT gateways require a public subnet tier."
    }
  }

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Private routing: one route table per tier per AZ.
# Per-tier tables are what let us add peering routes to the interconnect tier
# ONLY, and keep the data tier with nothing but the local route.
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  for_each = local.private_subnets
  vpc_id   = aws_vpc.this.id
  tags = merge(local.tags, {
    Name = "${var.name}-${each.key}"
    Tier = each.value.tier
  })
}

resource "aws_route_table_association" "private" {
  for_each       = local.private_subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route" "private_nat" {
  for_each = local.nat_routed_subnets

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = (
    var.nat_gateway_mode == "per_az"
    ? aws_nat_gateway.this[each.value.az].id
    : aws_nat_gateway.this[var.azs[0]].id
  )
}

# -----------------------------------------------------------------------------
# VPC endpoints: keep AWS API traffic (STS, KMS, logs, metrics...) off the
# internet and inside the region.
# -----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for k, rt in aws_route_table.private : rt.id]
  tags              = merge(local.tags, { Name = "${var.name}-s3" })
}

resource "aws_security_group" "endpoints" {
  count       = length(var.interface_endpoints) > 0 ? 1 : 0
  name        = "${var.name}-vpce"
  description = "Interface endpoints: HTTPS from inside this VPC only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count             = length(var.interface_endpoints) > 0 ? 1 : 0
  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from this VPC"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.endpoints[0].id]
  subnet_ids = [
    for k, s in local.subnets : aws_subnet.this[k].id if s.tier == var.endpoint_subnet_tier
  ]

  tags = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

# -----------------------------------------------------------------------------
# Data tier NACL: defence in depth. Even if someone adds a permissive SG or a
# stray route, the data subnets only talk to the app tier on the DB port.
# -----------------------------------------------------------------------------
locals {
  nacl_source_cidrs = var.data_tier_nacl == null ? [] : [
    for k, s in local.subnets : s.cidr if contains(var.data_tier_nacl.source_tiers, s.tier)
  ]
  nacl_ingress = var.data_tier_nacl == null ? [] : [
    for pair in setproduct(local.nacl_source_cidrs, var.data_tier_nacl.ports) : {
      cidr = pair[0]
      port = pair[1]
    }
  ]
}

resource "aws_network_acl" "data" {
  count  = var.data_tier_nacl == null ? 0 : 1
  vpc_id = aws_vpc.this.id
  subnet_ids = [
    for k, s in local.subnets : aws_subnet.this[k].id if s.tier == var.data_tier_nacl.tier
  ]

  dynamic "ingress" {
    for_each = local.nacl_ingress
    content {
      rule_no    = 100 + ingress.key * 10
      action     = "allow"
      protocol   = "tcp"
      cidr_block = ingress.value.cidr
      from_port  = ingress.value.port
      to_port    = ingress.value.port
    }
  }

  dynamic "egress" {
    for_each = local.nacl_source_cidrs
    content {
      rule_no    = 100 + egress.key * 10
      action     = "allow"
      protocol   = "tcp"
      cidr_block = egress.value
      from_port  = 1024
      to_port    = 65535
    }
  }

  # Everything else hits the implicit deny.
  tags = merge(local.tags, { Name = "${var.name}-${var.data_tier_nacl.tier}" })
}

# -----------------------------------------------------------------------------
# VPC Flow Logs -> KMS-encrypted CloudWatch Logs (+ REJECT metric)
# -----------------------------------------------------------------------------
resource "aws_kms_key" "flow_logs" {
  description             = "${var.name} VPC flow logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_logs_kms.json
  tags                    = local.tags
}

data "aws_iam_policy_document" "flow_logs_kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.flow_log_group_name}"]
    }
  }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = local.flow_log_group_name
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = aws_kms_key.flow_logs.arn
  tags              = local.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  # v5 fields add traffic-path and flow-direction, which make it possible to
  # tell "dropped at the peering boundary" from "dropped inside the VPC".
  log_format = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${vpc-id} $${subnet-id} $${az-id} $${tcp-flags} $${flow-direction} $${traffic-path}"

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_cloudwatch_log_metric_filter" "rejects" {
  name           = "${var.name}-flow-rejects"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name
  pattern        = "[version, account, eni, src, dst, srcport, dstport, protocol, packets, bytes, start, end, action=\"REJECT\", ...]"

  metric_transformation {
    name          = "FlowLogRejects"
    namespace     = "Network/FlowLogs"
    value         = "1"
    default_value = "0"
    dimensions = {
      VpcName = var.name
    }
  }
}
