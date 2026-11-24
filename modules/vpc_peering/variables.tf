variable "name" {
  description = "Peering name, e.g. \"hub-use1--spoke-eu\"."
  type        = string
}

variable "requester" {
  description = <<-EOT
    Requester side (always the hub in this design).
      vpc_id            - requester VPC
      route_table_ids   - map of static key => route table that gets routes TO the accepter
      destination_cidrs - accepter CIDRs to route to. Use specific subnet CIDRs, never the whole VPC.
  EOT
  type = object({
    vpc_id            = string
    route_table_ids   = map(string)
    destination_cidrs = list(string)
  })
}

variable "accepter" {
  description = <<-EOT
    Accepter side (the regional spoke, or the second hub for hub<->hub).
      vpc_id            - accepter VPC
      route_table_ids   - map of static key => route table that gets return routes TO the requester
      destination_cidrs - requester CIDRs to route back to.
  EOT
  type = object({
    vpc_id            = string
    route_table_ids   = map(string)
    destination_cidrs = list(string)
  })
}

variable "allow_remote_dns_resolution" {
  description = "Resolve the peer's private DNS hostnames to private IPs. Needed so the hub resolves the regional gateway's internal ALB name to its private address."
  type        = bool
  default     = true
}

variable "max_route_prefix" {
  description = "Guard-rail: the broadest prefix allowed as a peering route destination. Prevents someone routing an entire VPC (or 0.0.0.0/0) across a residency boundary."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
