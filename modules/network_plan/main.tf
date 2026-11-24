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
    compact([try(local.plan.monitoring.account_id, null)]),
  ))
}

# -----------------------------------------------------------------------------
# Guard-rail: VPC CIDRs must not overlap (VPC peering can't route overlapping
# ranges). Two ranges overlap when their network addresses match at the shorter
# of the two prefix lengths. Checked as an output precondition, so EVERY stack
# that reads the plan fails its plan if someone introduces an overlap.
# -----------------------------------------------------------------------------
locals {
  vpc_cidrs = merge(
    { for k, v in local.plan.hubs : "hub-${k}" => v.cidr },
    { for k, v in local.plan.spokes : "spoke-${k}" => v.cidr },
  )
  vpc_names  = sort(keys(local.vpc_cidrs))
  vpc_prefix = { for k, c in local.vpc_cidrs : k => tonumber(split("/", c)[1]) }

  cidr_overlaps = flatten([
    for i, a in local.vpc_names : [
      for b in slice(local.vpc_names, i + 1, length(local.vpc_names)) :
      "${a} (${local.vpc_cidrs[a]}) overlaps ${b} (${local.vpc_cidrs[b]})"
      if cidrhost("${cidrhost(local.vpc_cidrs[a], 0)}/${min(local.vpc_prefix[a], local.vpc_prefix[b])}", 0)
      == cidrhost("${cidrhost(local.vpc_cidrs[b], 0)}/${min(local.vpc_prefix[a], local.vpc_prefix[b])}", 0)
    ]
  ])
}

output "vpc_cidrs" {
  value       = local.vpc_cidrs
  description = "Every VPC's CIDR, keyed hub-<name> / spoke-<name>. Fails the plan if any two overlap."

  precondition {
    condition     = length(local.cidr_overlaps) == 0
    error_message = "Overlapping VPC CIDRs in the network plan (VPC peering cannot route these): ${join("; ", local.cidr_overlaps)}"
  }
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
    Repository  = "AWS-multi-region-observability-network"
  }
  description = "Tags every stack applies via provider default_tags."
}
