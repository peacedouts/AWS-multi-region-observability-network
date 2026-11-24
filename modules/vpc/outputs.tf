output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids_by_tier" {
  description = "Map of tier => list of subnet IDs (AZ order)."
  value = {
    for tier in keys(var.subnet_tiers) : tier => [
      for az in var.azs : aws_subnet.this["${tier}-${az}"].id
    ]
  }
}

output "subnet_cidrs_by_tier" {
  description = "Map of tier => list of subnet CIDRs (AZ order). Used as tight peering route destinations and SG sources."
  value = {
    for tier in keys(var.subnet_tiers) : tier => [
      for az in var.azs : local.subnets["${tier}-${az}"].cidr
    ]
  }
}

output "route_table_ids_by_tier" {
  description = "Map of private tier => map of \"<tier>-<az>\" => route table ID. Keys are static so callers can for_each over them safely."
  value = {
    for tier in local.private_tiers : tier => {
      for k, s in local.private_subnets : k => aws_route_table.private[k].id if s.tier == tier
    }
  }
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "nat_public_ips" {
  description = "NAT gateway EIPs (for allow-listing at third parties such as the IdP)."
  value       = [for e in aws_eip.nat : e.public_ip]
}
