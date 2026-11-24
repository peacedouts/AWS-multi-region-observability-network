###############################################################################
# One provider per (account, region) that takes part in peering.
# Each assumes the deployer role in its own account, so a single plan shows
# BOTH sides of every connection and its routes. Changes are reviewed as one
# diff, applied as one unit.
###############################################################################

terraform {
  required_version = ">= 1.10"
  backend "s3" {} # backends/prod.hcl

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 6.0"
    }
  }
}

locals {
  raw  = yamldecode(file("${path.module}/../network-plan.yaml"))
  role = local.raw.pipeline_role_name
  tags = {
    Environment = local.raw.environment
    System      = "central-observability"
    Repository  = "AWS-multi-region-observability-network"
    Stack       = "connectivity"
    Owner       = "platform-infrastructure"
  }
}

provider "aws" {
  alias               = "hub_use1"
  region              = local.raw.hubs.use1.region
  allowed_account_ids = [local.raw.hubs.use1.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.hubs.use1.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = local.tags }
}

provider "aws" {
  alias               = "hub_euw1"
  region              = local.raw.hubs.euw1.region
  allowed_account_ids = [local.raw.hubs.euw1.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.hubs.euw1.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = local.tags }
}

provider "aws" {
  alias               = "spoke_us"
  region              = local.raw.spokes.us.region
  allowed_account_ids = [local.raw.spokes.us.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.spokes.us.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = merge(local.tags, { DataResidency = "us" }) }
}

provider "aws" {
  alias               = "spoke_eu"
  region              = local.raw.spokes.eu.region
  allowed_account_ids = [local.raw.spokes.eu.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.spokes.eu.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = merge(local.tags, { DataResidency = "eu" }) }
}

provider "aws" {
  alias               = "spoke_ca"
  region              = local.raw.spokes.ca.region
  allowed_account_ids = [local.raw.spokes.ca.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.spokes.ca.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = merge(local.tags, { DataResidency = "ca" }) }
}

provider "aws" {
  alias               = "spoke_apac"
  region              = local.raw.spokes.apac.region
  allowed_account_ids = [local.raw.spokes.apac.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.raw.spokes.apac.account_id}:role/${local.role}"
    session_name = "tf-connectivity"
  }
  default_tags { tags = merge(local.tags, { DataResidency = "apac" }) }
}
