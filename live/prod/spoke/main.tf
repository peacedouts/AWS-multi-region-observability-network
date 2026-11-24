###############################################################################
# live/prod/spoke  — one instance per jurisdiction (us, eu, ca, apac)
#
#   terraform init -backend-config=backends/eu.hcl
#   terraform apply -var spoke=eu
#
# Runs in the REGIONAL account with a provider pinned to that region and
# allowed_account_ids pinned to that account, so a mis-typed -var can never
# create EU resources in the US account (and the region-lock SCP backs this up).
#
# Brownfield note: the regional stacks already exist. In practice this root
# would `import` the existing VPC/subnets and only ADD the interconnect tier,
# the gateway SG and the guard-rails. Shown greenfield for clarity.
###############################################################################

terraform {
  required_version = ">= 1.10"
  backend "s3" {} # partial config in backends/<spoke>.hcl

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 6.0"
    }
  }
}

variable "spoke" {
  type        = string
  description = "Spoke key from network-plan.yaml (us | eu | ca | apac)."
}

variable "security_alert_topic_arn" {
  type        = string
  description = "Regional security SNS topic (owned by the regional account baseline)."
  default     = ""
}

locals {
  raw = yamldecode(file("${path.module}/../network-plan.yaml"))
  me  = local.raw.spokes[var.spoke]
}

provider "aws" {
  region              = local.me.region
  allowed_account_ids = [local.me.account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${local.me.account_id}:role/${local.raw.pipeline_role_name}"
    session_name = "tf-spoke-${var.spoke}"
  }

  default_tags {
    tags = {
      Environment   = local.raw.environment
      System        = "central-observability"
      Repository    = "AWS-multi-region-observability-network"
      Stack         = "spoke-${var.spoke}"
      DataResidency = var.spoke
      Owner         = "platform-infrastructure"
    }
  }
}

module "plan" {
  source    = "../../../modules/network_plan"
  plan_file = "${path.module}/../network-plan.yaml"
}

locals {
  name = "${local.raw.org_prefix}-spoke-${var.spoke}"
  me_d = module.plan.spokes[var.spoke]
}

module "vpc" {
  source = "../../../modules/vpc"

  name             = local.name
  cidr_block       = local.me.cidr
  azs              = local.me.azs
  subnet_tiers     = module.plan.subnet_layouts.spoke
  nat_gateway_mode = "per_az"
  nat_egress_tiers = ["app"] # data and interconnect tiers never get a default route

  data_tier_nacl = {
    tier         = "data"
    source_tiers = ["app"] # NOT interconnect: the hub-facing tier can never reach Aurora directly
    ports        = [5432]
  }
}

module "regional_gateway_sg" {
  source = "../../../modules/security_groups/regional_gateway"

  name   = local.name
  vpc_id = module.vpc.vpc_id

  hub_source_cidrs = {
    for k, h in module.plan.hubs : "hub-${k}" => h.subnet_cidrs_by_tier.app
  }
  target_cidrs = local.me_d.subnet_cidrs_by_tier.app
  target_port  = 8443
}

module "page_topic" {
  count  = var.security_alert_topic_arn == "" ? 1 : 0
  source = "../../../modules/alert_topic"
  name   = "${local.name}-network-security"
}

module "guardrails" {
  source = "../../../modules/network_guardrails"

  name               = local.name
  pipeline_role_arns = module.plan.pipeline_role_arns
  alert_topic_arn    = var.security_alert_topic_arn != "" ? var.security_alert_topic_arn : module.page_topic[0].topic_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "interconnect_route_table_ids" {
  value = module.vpc.route_table_ids_by_tier.interconnect
}

output "interconnect_subnet_ids" {
  value = module.vpc.subnet_ids_by_tier.interconnect
}

output "regional_gateway_security_group_id" {
  value = module.regional_gateway_sg.security_group_id
}
