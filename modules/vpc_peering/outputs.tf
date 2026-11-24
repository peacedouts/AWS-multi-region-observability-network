output "peering_connection_id" {
  description = "VPC peering connection ID."
  value       = aws_vpc_peering_connection_accepter.this.id
}

output "accept_status" {
  description = "Peering status as seen by the accepter (should be \"active\")."
  value       = aws_vpc_peering_connection_accepter.this.accept_status
}

output "requester_route_count" {
  description = "Number of routes added on the requester side."
  value       = length(aws_route.requester)
}

output "accepter_route_count" {
  description = "Number of routes added on the accepter side."
  value       = length(aws_route.accepter)
}
