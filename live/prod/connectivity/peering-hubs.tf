###############################################################################
# hub-use1 <-> hub-euw1
#
# Cross-hub fallback: if hub A loses its path to region X but hub B still has
# one, hub A's central API forwards X-bound calls to hub B instead of failing.
# Hubs hold no event data, so this path carries only in-flight API traffic.
###############################################################################
module "peer_hub_use1_hub_euw1" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_use1
    aws.accepter  = aws.hub_euw1
  }

  name = "hub-use1--hub-euw1"

  requester = {
    vpc_id            = local.hub["use1"].vpc_id
    route_table_ids   = local.hub["use1"].app_route_table_ids
    destination_cidrs = local.hub_app_cidrs["euw1"]
  }

  accepter = {
    vpc_id            = local.hub["euw1"].vpc_id
    route_table_ids   = local.hub["euw1"].app_route_table_ids
    destination_cidrs = local.hub_app_cidrs["use1"]
  }
}
