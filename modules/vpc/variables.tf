variable "name" {
  description = "Name prefix for every resource, e.g. \"spoke-eu\" or \"hub-use1\"."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must come from network-plan.yaml so it never overlaps another VPC (peering requires non-overlapping ranges)."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be a valid IPv4 CIDR of /20 or larger."
  }
}

variable "azs" {
  description = "Availability zones to spread every tier across. Three is the default for regional HA."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two AZs are required; three is recommended."
  }
}

variable "subnet_tiers" {
  description = <<-EOT
    Subnet tiers. One subnet per AZ is created for each tier at
    cidrsubnet(cidr_block, newbits, netnum_base + az_index).

    The defaults implement the reference three-tier layout plus an
    "interconnect" tier: the ONLY subnets that peered VPCs can route to.
  EOT
  type = map(object({
    newbits     = number
    netnum_base = number
    public      = optional(bool, false)
  }))

  default = {
    public       = { newbits = 8, netnum_base = 0, public = true } # /24s  x.x.0-2.0
    app          = { newbits = 4, netnum_base = 1 }                # /20s  x.x.16.0 - x.x.63.255
    data         = { newbits = 4, netnum_base = 4 }                # /20s  x.x.64.0 - x.x.111.255
    interconnect = { newbits = 8, netnum_base = 240 }              # /24s  x.x.240-242.0
  }
}

variable "nat_gateway_mode" {
  description = "\"per_az\" (HA, default), \"single\" (cost-saving, non-prod) or \"none\" (no internet egress at all)."
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["per_az", "single", "none"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be per_az, single or none."
  }
}

variable "nat_egress_tiers" {
  description = "Private tiers that get a default route to NAT. Data and interconnect tiers should never be listed here."
  type        = list(string)
  default     = ["app"]
}

variable "data_tier_nacl" {
  description = <<-EOT
    Stateless guard-rail on the data tier, independent of security groups.
    Only the listed source tiers may reach the listed ports. Set to null to skip.
  EOT
  type = object({
    tier         = string
    source_tiers = list(string)
    ports        = list(number)
  })
  default = {
    tier         = "data"
    source_tiers = ["app"]
    ports        = [5432]
  }
}

variable "interface_endpoints" {
  description = "AWS services to reach over PrivateLink instead of NAT (e.g. sts, logs, monitoring, secretsmanager, ecr.api, ecr.dkr)."
  type        = list(string)
  default     = ["sts", "logs", "monitoring", "secretsmanager", "kms", "ecr.api", "ecr.dkr"]
}

variable "endpoint_subnet_tier" {
  description = "Tier that hosts interface endpoint ENIs."
  type        = string
  default     = "app"
}

variable "flow_log_retention_days" {
  description = "Retention of VPC Flow Logs in CloudWatch. Flow logs carry no PII (assumption in docs) and are shared to the observability account via OAM."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to every resource. Must include data_residency and owner (enforced by tag policy)."
  type        = map(string)
  default     = {}
}
