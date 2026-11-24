###############################################################################
# modules/security_groups/central_api  (deployed in each HUB)
#
# Egress-restricted SG for the central API tasks and the connectivity probe.
# Default-deny egress: they can talk to regional gateways, the peer hub,
# in-VPC endpoints, and (optionally) the corporate IdP through NAT.
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix."
}

variable "vpc_id" {
  type        = string
  description = "Hub VPC ID."
}

variable "vpc_cidr" {
  type        = string
  description = "Hub VPC CIDR (for interface endpoints)."
}

variable "regional_gateway_cidrs" {
  type        = map(list(string))
  description = "Spoke name => interconnect CIDRs of that spoke's regional gateway."
}

variable "peer_hub_cidrs" {
  type        = list(string)
  default     = []
  description = "App-subnet CIDRs of the other hub (cross-hub fallback path)."
}

variable "allow_https_internet_egress" {
  type        = bool
  default     = false
  description = "Allow 443 to 0.0.0.0/0 via NAT (IdP JWKS, cross-region CloudWatch writes). In production, pair with AWS Network Firewall domain allow-listing."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  regional = merge([
    for spoke, cidrs in var.regional_gateway_cidrs : {
      for c in cidrs : "${spoke}|${c}" => { spoke = spoke, cidr = c }
    }
  ]...)
}

resource "aws_security_group" "this" {
  name        = "${var.name}-central-api"
  description = "Central API tasks and connectivity probes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-central-api" })
}

resource "aws_vpc_security_group_egress_rule" "to_regional_gateways" {
  for_each = local.regional

  security_group_id = aws_security_group.this.id
  description       = "mTLS to regional gateway ${each.value.spoke}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = { TargetSpoke = each.value.spoke }
}

resource "aws_vpc_security_group_egress_rule" "to_peer_hub" {
  for_each = toset(var.peer_hub_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Cross-hub fallback"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "from_peer_hub" {
  for_each = toset(var.peer_hub_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Cross-hub fallback"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "to_vpc_endpoints" {
  security_group_id = aws_security_group.this.id
  description       = "AWS APIs via interface endpoints"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "https_internet" {
  count = var.allow_https_internet_egress ? 1 : 0

  security_group_id = aws_security_group.this.id
  description       = "HTTPS via NAT (IdP, cross-region metrics)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Attach to central API ECS services and the probe Lambda."
}
