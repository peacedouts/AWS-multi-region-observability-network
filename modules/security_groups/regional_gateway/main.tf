###############################################################################
# modules/security_groups/regional_gateway  (deployed in each SPOKE)
#
# SG for the regional gateway's internal ALB, which lives in the interconnect
# tier. It is the single front door the central API may use to read/write a
# region's data. Cross-region SG references are not supported by AWS, so the
# sources are the hub app-subnet CIDRs (the same CIDRs the peering routes).
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix."
}

variable "vpc_id" {
  type        = string
  description = "Spoke VPC ID."
}

variable "hub_source_cidrs" {
  type        = map(list(string))
  description = "Hub name => hub app-subnet CIDRs allowed to call the gateway, e.g. { hub-use1 = [\"10.10.16.0/20\", ...] }."
}

variable "listener_port" {
  type        = number
  default     = 443
  description = "ALB listener port (HTTPS, mutual TLS)."
}

variable "target_cidrs" {
  type        = list(string)
  description = "Regional app-tier CIDRs where the gateway Fargate tasks run."
}

variable "target_port" {
  type        = number
  default     = 8443
  description = "Port the gateway tasks listen on."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  ingress = merge([
    for hub, cidrs in var.hub_source_cidrs : {
      for c in cidrs : "${hub}|${c}" => { hub = hub, cidr = c }
    }
  ]...)
}

resource "aws_security_group" "this" {
  name        = "${var.name}-regional-gateway-alb"
  description = "Regional gateway ALB: mTLS from central hubs only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-regional-gateway-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "from_hubs" {
  for_each = local.ingress

  security_group_id = aws_security_group.this.id
  description       = "HTTPS (mTLS) from ${each.value.hub}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = var.listener_port
  to_port           = var.listener_port
  tags              = { SourceHub = each.value.hub }
}

resource "aws_vpc_security_group_egress_rule" "to_targets" {
  for_each = toset(var.target_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "To regional gateway tasks"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.target_port
  to_port           = var.target_port
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Attach to the regional gateway internal ALB."
}
