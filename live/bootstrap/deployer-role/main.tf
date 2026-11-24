###############################################################################
# live/bootstrap/deployer-role
#
# Run once per account by a platform admin (break-glass credentials), before
# any other stack. After this, every network change goes through CI.
#
#   terraform apply -var account=eu
###############################################################################

terraform {
  required_version = ">= 1.10"
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 6.0"
    }
  }
}

variable "account" {
  type        = string
  description = "Hub or spoke key from network-plan.yaml, or \"monitoring\"."
}

variable "pipeline_role_arn" {
  type        = string
  description = "GitHub Actions OIDC role in the tooling account."
  default     = "arn:aws:iam::999999999999:role/github-actions-network-pipeline"
}

locals {
  raw = yamldecode(file("${path.module}/../../prod/network-plan.yaml"))
  target = merge(
    local.raw.hubs,
    local.raw.spokes,
    { monitoring = merge(local.raw.monitoring, { region = local.raw.hubs.use1.region }) },
  )[var.account]
}

provider "aws" {
  region              = local.target.region
  allowed_account_ids = [local.target.account_id]
}

module "deployer" {
  source = "../../../modules/iam_network_deployer"

  role_name                  = local.raw.pipeline_role_name
  trusted_pipeline_role_arns = [var.pipeline_role_arn]
  github_repository          = "peacedouts/AWS-multi-region-observability-network"
}

output "deployer_role_arn" {
  value = module.deployer.role_arn
}
