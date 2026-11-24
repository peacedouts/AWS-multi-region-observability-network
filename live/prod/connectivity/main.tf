###############################################################################
# live/prod/connectivity
#
# Topology: dual hub-and-spoke.
#   2 hubs x 4 spokes = 8 hub->spoke peerings  (every region reachable from both hubs)
#   + 1 hub<->hub peering                      (cross-hub fallback path)
#
# There is deliberately NO spoke<->spoke peering, and peering is not
# transitive, so no regional VPC can ever reach another regional VPC.
#
# Routes are subnet-precise:
#   hub app subnets            -> spoke interconnect subnets   (hub side)
#   spoke interconnect subnets -> hub app subnets              (spoke side, return path)
# Spoke app/data route tables get nothing.
###############################################################################

module "plan" {
  source    = "../../../modules/network_plan"
  plan_file = "${path.module}/../network-plan.yaml"
}

# IDs (VPC, route tables) come from the owning stacks' state. CIDRs come from
# the plan, so a CIDR change is always a reviewed change to network-plan.yaml.
data "terraform_remote_state" "hub" {
  for_each = module.plan.hubs
  backend  = "s3"
  config = {
    bucket = local.raw.state_bucket
    key    = "network/hub/${each.key}.tfstate"
    region = local.raw.state_region
  }
}

data "terraform_remote_state" "spoke" {
  for_each = module.plan.spokes
  backend  = "s3"
  config = {
    bucket = local.raw.state_bucket
    key    = "network/spoke/${each.key}.tfstate"
    region = local.raw.state_region
  }
}

locals {
  hub   = { for k, v in data.terraform_remote_state.hub : k => v.outputs }
  spoke = { for k, v in data.terraform_remote_state.spoke : k => v.outputs }

  hub_app_cidrs            = { for k, h in module.plan.hubs : k => h.subnet_cidrs_by_tier.app }
  spoke_interconnect_cidrs = { for k, s in module.plan.spokes : k => s.subnet_cidrs_by_tier.interconnect }
}
