###############################################################################
# live/prod/hub  — one instance per hub (use1, euw1)
#
#   terraform init -backend-config=backends/use1.hcl
#   terraform apply -var hub=use1
#
# Creates the hub VPC, the egress-restricted central API security group,
# alert topics and change guard-rails. Peering lives in ../connectivity.
###############################################################################

terraform {
  required_version = ">= 1.10"
  backend "s3" {} # partial config in backends/<hub>.hcl

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 6.0"
    }
  }
}

variable "hub" {
  type        = string
  description = "Hub key from network-plan.yaml (use1 | euw1)."
}

variable "page_endpoints" {
  type        = list(string)
  default     = []
  sensitive   = true
  description = "Incident-tool HTTPS integration URL(s) for pages."
}

variable "ticket_endpoints" {
  type        = list(string)
  default     = []
  sensitive   = true
  description = "Incident-tool HTTPS integration URL(s) for tickets."
}

locals {
  raw = yamldecode(file("${path.module}/../network-plan.yaml"))
  me  = local.raw.hubs[var.hub]
}

provider "aws" {
  region              = local.me.region
  allowed_account_ids = [local.me.account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${local.me.account_id}:role/${local.raw.pipeline_role_name}"
    session_name = "tf-hub-${var.hub}"
  }

  default_tags {
    tags = {
      Environment   = local.raw.environment
      System        = "central-observability"
      Repository    = "multi-region-observability-network"
      Stack         = "hub-${var.hub}"
      DataResidency = "none-no-event-data-at-rest"
      Owner         = "platform-infrastructure"
    }
  }
}

module "plan" {
  source    = "../../../modules/network_plan"
  plan_file = "${path.module}/../network-plan.yaml"
}

locals {
  name      = "${local.raw.org_prefix}-hub-${var.hub}"
  peer_hubs = { for k, v in module.plan.hubs : k => v if k != var.hub }
}

module "vpc" {
  source = "../../../modules/vpc"

  name             = local.name
  cidr_block       = local.me.cidr
  azs              = local.me.azs
  subnet_tiers     = module.plan.subnet_layouts.hub
  nat_gateway_mode = "per_az"
  nat_egress_tiers = ["app"]
  data_tier_nacl   = null # hubs have no data tier: nothing is stored centrally
}

module "central_api_sg" {
  source = "../../../modules/security_groups/central_api"

  name     = local.name
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr

  regional_gateway_cidrs = {
    for k, s in module.plan.spokes : k => s.subnet_cidrs_by_tier.interconnect
  }
  peer_hub_cidrs = flatten([for k, h in local.peer_hubs : h.subnet_cidrs_by_tier.app])

  allow_https_internet_egress = true # IdP JWKS + dual-region metric writes; front with Network Firewall in prod
}

module "page_topic" {
  source          = "../../../modules/alert_topic"
  name            = "${local.name}-network-page"
  https_endpoints = var.page_endpoints
}

module "ticket_topic" {
  source          = "../../../modules/alert_topic"
  name            = "${local.name}-network-ticket"
  https_endpoints = var.ticket_endpoints
}

module "guardrails" {
  source = "../../../modules/network_guardrails"

  name               = local.name
  pipeline_role_arns = module.plan.pipeline_role_arns
  alert_topic_arn    = module.page_topic.topic_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "app_subnet_ids" {
  value = module.vpc.subnet_ids_by_tier.app
}

output "app_route_table_ids" {
  value = module.vpc.route_table_ids_by_tier.app
}

output "central_api_security_group_id" {
  value = module.central_api_sg.security_group_id
}

output "page_topic_arn" {
  value = module.page_topic.topic_arn
}

output "ticket_topic_arn" {
  value = module.ticket_topic.topic_arn
}
