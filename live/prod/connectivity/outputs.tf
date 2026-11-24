output "peering_connections" {
  description = "All peering connection IDs, for runbooks and the monitoring dashboards."
  value = {
    "hub-use1--spoke-us"   = module.peer_hub_use1_spoke_us.peering_connection_id
    "hub-euw1--spoke-us"   = module.peer_hub_euw1_spoke_us.peering_connection_id
    "hub-use1--spoke-eu"   = module.peer_hub_use1_spoke_eu.peering_connection_id
    "hub-euw1--spoke-eu"   = module.peer_hub_euw1_spoke_eu.peering_connection_id
    "hub-use1--spoke-ca"   = module.peer_hub_use1_spoke_ca.peering_connection_id
    "hub-euw1--spoke-ca"   = module.peer_hub_euw1_spoke_ca.peering_connection_id
    "hub-use1--spoke-apac" = module.peer_hub_use1_spoke_apac.peering_connection_id
    "hub-euw1--spoke-apac" = module.peer_hub_euw1_spoke_apac.peering_connection_id
    "hub-use1--hub-euw1"   = module.peer_hub_use1_hub_euw1.peering_connection_id
  }
}
