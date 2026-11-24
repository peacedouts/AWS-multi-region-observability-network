###############################################################################
# APAC spoke <-> both hubs
###############################################################################

module "peer_hub_use1_spoke_apac" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_use1
    aws.accepter  = aws.spoke_apac
  }

  name = "hub-use1--spoke-apac"

  requester = {
    vpc_id            = local.hub["use1"].vpc_id
    route_table_ids   = local.hub["use1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["apac"]
  }

  accepter = {
    vpc_id            = local.spoke["apac"].vpc_id
    route_table_ids   = local.spoke["apac"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["use1"]
  }
}

module "peer_hub_euw1_spoke_apac" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_euw1
    aws.accepter  = aws.spoke_apac
  }

  name = "hub-euw1--spoke-apac"

  requester = {
    vpc_id            = local.hub["euw1"].vpc_id
    route_table_ids   = local.hub["euw1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["apac"]
  }

  accepter = {
    vpc_id            = local.spoke["apac"].vpc_id
    route_table_ids   = local.spoke["apac"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["euw1"]
  }
}
