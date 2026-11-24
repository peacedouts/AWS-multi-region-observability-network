###############################################################################
# modules/network_plan
#
# Pure data module (no resources). Reads network-plan.yaml and derives every
# VPC's subnet CIDRs. Stacks use it to build tight routes and SG rules for the
# OTHER side of a peering without coupling to that side's Terraform state.
###############################################################################

terraform {
  required_version = ">= 1.10"
}

variable "plan_file" {
  type        = string
  description = "Path to network-plan.yaml."
}

locals {
  plan = yamldecode(file(var.plan_file))

  derive = {
    for role, group in { hub = local.plan.hubs, spoke = local.plan.spokes } : role => {
      for name, v in group : name => merge(v, {
        role = role
        subnet_cidrs_by_tier = {
          for tier, cfg in local.plan.subnet_layouts[role] : tier => [
            for i in range(length(v.azs)) : cidrsubnet(v.cidr, cfg.newbits, cfg.netnum_base + i)
          ]
        }
      })
    }
  }

  all_accounts = distinct(concat(
    [for h in local.plan.hubs : h.account_id],
    [for s in local.plan.spokes : s.account_id],
  ))
}

output "raw" {
  value       = local.plan
  description = "The decoded plan file."
}

output "hubs" {
  value       = local.derive.hub
  description = "Hub name => {account_id, region, cidr, azs, subnet_cidrs_by_tier}."
}

output "spokes" {
  value       = local.derive.spoke
  description = "Spoke name => {account_id, region, cidr, azs, allowed_regions, gateway_fqdn, subnet_cidrs_by_tier}."
}

output "subnet_layouts" {
  value       = local.plan.subnet_layouts
  description = "Subnet layout per role (hub/spoke)."
}

output "pipeline_role_arns" {
  value       = [for a in local.all_accounts : "arn:aws:iam::${a}:role/${local.plan.pipeline_role_name}"]
  description = "Deployer role ARN in every account (the only principals allowed to change the network)."
}

output "base_tags" {
  value = {
    Environment = local.plan.environment
    System      = "central-observability"
    Repository  = "multi-region-observability-network"
  }
  description = "Tags every stack applies via provider default_tags."
}
