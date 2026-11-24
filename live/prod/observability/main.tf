###############################################################################
# live/prod/observability  — one instance per hub region (use1, euw1)
#
#   terraform init -backend-config=backends/use1.hcl
#   terraform apply -var hub=use1
#
# Deploys this hub's connectivity probe and the FULL hub x region alarm matrix
# (both hubs' probes dual-write metrics here), so either region alone can
# detect and page on any connectivity failure.
###############################################################################

terraform {
  required_version = ">= 1.10"
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

variable "hub" {
  type        = string
  description = "Hub key (use1 | euw1)."
}

variable "mtls_secret_arn" {
  type        = string
  default     = ""
  description = "Secret with the probe's mTLS client certificate (issued by AWS Private CA)."
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
    session_name = "tf-observability-${var.hub}"
  }
  default_tags {
    tags = {
      Environment = local.raw.environment
      System      = "central-observability"
      Repository  = "multi-region-observability-network"
      Stack       = "observability-${var.hub}"
      Owner       = "platform-infrastructure"
    }
  }
}

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = local.raw.state_bucket
    key    = "network/hub/${var.hub}.tfstate"
    region = local.raw.state_region
  }
}

locals {
  hub = data.terraform_remote_state.hub.outputs
}

module "probe" {
  source = "../../../modules/connectivity_probe"

  name       = "${local.raw.org_prefix}-hub-${var.hub}"
  source_hub = var.hub
  targets = [
    for k, s in local.raw.spokes : { region = k, host = s.gateway_fqdn }
  ]
  metric_regions     = distinct([for h in local.raw.hubs : h.region])
  subnet_ids         = local.hub.app_subnet_ids
  security_group_ids = [local.hub.central_api_security_group_id]
  mtls_secret_arn    = var.mtls_secret_arn
}

module "alerting" {
  source = "../../../modules/connectivity_alerting"

  hubs                      = keys(local.raw.hubs)
  regions                   = keys(local.raw.spokes)
  page_topic_arn            = local.hub.page_topic_arn
  ticket_topic_arn          = local.hub.ticket_topic_arn
  runbook_base_url          = local.raw.runbook_base_url
  local_probe_function_name = module.probe.function_name

  # Set from two weeks of measured baseline (~1.5x observed p99). Illustrative values.
  latency_p99_threshold_ms = {
    "use1|us"   = 20
    "use1|ca"   = 60
    "use1|eu"   = 150
    "use1|apac" = 330
    "euw1|us"   = 150
    "euw1|ca"   = 160
    "euw1|eu"   = 60
    "euw1|apac" = 450
  }
}
