###############################################################################
# US spoke <-> both hubs
###############################################################################

module "peer_hub_use1_spoke_us" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_use1
    aws.accepter  = aws.spoke_us
  }

  name = "hub-use1--spoke-us"

  requester = {
    vpc_id            = local.hub["use1"].vpc_id
    route_table_ids   = local.hub["use1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["us"]
  }

  accepter = {
    vpc_id            = local.spoke["us"].vpc_id
    route_table_ids   = local.spoke["us"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["use1"]
  }
}

module "peer_hub_euw1_spoke_us" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_euw1
    aws.accepter  = aws.spoke_us
  }

  name = "hub-euw1--spoke-us"

  requester = {
    vpc_id            = local.hub["euw1"].vpc_id
    route_table_ids   = local.hub["euw1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["us"]
  }

  accepter = {
    vpc_id            = local.spoke["us"].vpc_id
    route_table_ids   = local.spoke["us"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["euw1"]
  }
}
