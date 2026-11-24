###############################################################################
# CA spoke <-> both hubs
###############################################################################

module "peer_hub_use1_spoke_ca" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_use1
    aws.accepter  = aws.spoke_ca
  }

  name = "hub-use1--spoke-ca"

  requester = {
    vpc_id            = local.hub["use1"].vpc_id
    route_table_ids   = local.hub["use1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["ca"]
  }

  accepter = {
    vpc_id            = local.spoke["ca"].vpc_id
    route_table_ids   = local.spoke["ca"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["use1"]
  }
}

module "peer_hub_euw1_spoke_ca" {
  source = "../../../modules/vpc_peering"
  providers = {
    aws.requester = aws.hub_euw1
    aws.accepter  = aws.spoke_ca
  }

  name = "hub-euw1--spoke-ca"

  requester = {
    vpc_id            = local.hub["euw1"].vpc_id
    route_table_ids   = local.hub["euw1"].app_route_table_ids
    destination_cidrs = local.spoke_interconnect_cidrs["ca"]
  }

  accepter = {
    vpc_id            = local.spoke["ca"].vpc_id
    route_table_ids   = local.spoke["ca"].interconnect_route_table_ids
    destination_cidrs = local.hub_app_cidrs["euw1"]
  }
}
