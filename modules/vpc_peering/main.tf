###############################################################################
# modules/vpc_peering
#
# Cross-account AND cross-region VPC peering, including both sides' routes.
# The caller passes two provider configurations (aws.requester, aws.accepter),
# each assuming the deployer role in its own account/region, so a single
# apply creates, accepts and routes the connection with no manual step.
#
# Design notes
#   * Peering is non-transitive. That is a feature here: spoke-eu can never
#     reach spoke-us through the hub, which is exactly what residency needs.
#   * Inter-region peering traffic stays on the AWS backbone and is encrypted
#     by AWS. We still use mTLS at L7 (see docs/architecture.md).
#   * Security groups cannot reference SGs across regions, so the SG layer
#     uses the same tight CIDRs that this module routes.
###############################################################################

data "aws_caller_identity" "accepter" {
  provider = aws.accepter
}

data "aws_region" "accepter" {
  provider = aws.accepter
}

locals {
  all_destinations = concat(var.requester.destination_cidrs, var.accepter.destination_cidrs)

  requester_routes = {
    for pair in setproduct(keys(var.requester.route_table_ids), var.requester.destination_cidrs) :
    "${pair[0]}|${pair[1]}" => {
      route_table_id = var.requester.route_table_ids[pair[0]]
      cidr           = pair[1]
    }
  }

  accepter_routes = {
    for pair in setproduct(keys(var.accepter.route_table_ids), var.accepter.destination_cidrs) :
    "${pair[0]}|${pair[1]}" => {
      route_table_id = var.accepter.route_table_ids[pair[0]]
      cidr           = pair[1]
    }
  }

  tags = merge(var.tags, { ManagedBy = "terraform", Module = "vpc_peering", Peering = var.name })
}

resource "terraform_data" "route_guardrail" {
  lifecycle {
    precondition {
      condition = alltrue([
        for c in local.all_destinations : tonumber(split("/", c)[1]) >= var.max_route_prefix
      ])
      error_message = "Peering routes must be specific subnet CIDRs (/${var.max_route_prefix} or narrower). Routing whole VPCs across a residency boundary is not allowed."
    }
  }
}

# -----------------------------------------------------------------------------
# Connection
# -----------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "this" {
  provider = aws.requester

  vpc_id        = var.requester.vpc_id
  peer_vpc_id   = var.accepter.vpc_id
  peer_owner_id = data.aws_caller_identity.accepter.account_id
  peer_region   = data.aws_region.accepter.name
  auto_accept   = false # cross-account/region: accepted explicitly below

  tags = merge(local.tags, { Name = var.name, Side = "requester" })

  depends_on = [terraform_data.route_guardrail]
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = merge(local.tags, { Name = var.name, Side = "accepter" })
}

# Options must be set from each owning account separately for cross-account peering.
resource "aws_vpc_peering_connection_options" "requester" {
  provider = aws.requester

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = var.allow_remote_dns_resolution
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = var.allow_remote_dns_resolution
  }
}

# -----------------------------------------------------------------------------
# Routes: narrow, explicit, both directions
# -----------------------------------------------------------------------------
resource "aws_route" "requester" {
  provider = aws.requester
  for_each = local.requester_routes

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

resource "aws_route" "accepter" {
  provider = aws.accepter
  for_each = local.accepter_routes

  route_table_id            = each.value.route_table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}
