###############################################################################
# live/prod/monitoring  — one instance per hub region (use1, euw1)
#
#   terraform init -backend-config=backends/use1.hcl
#   terraform apply -var hub=use1
#
# Two accounts are involved:
#   * the HUB account runs this hub's connectivity probe, inside the hub VPC,
#     so it tests the real network path;
#   * the MONITORING account holds the probe metrics and the full
#     hub x region alarm matrix. Every hub's probe writes there (in both hub
#     regions) through a write-only role, so alarms see the whole matrix even
#     though each hub lives in its own account.
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
  raw           = yamldecode(file("${path.module}/../network-plan.yaml"))
  me            = local.raw.hubs[var.hub]
  monitoring_id = local.raw.monitoring.account_id
  prefix        = "${local.raw.org_prefix}-hub-${var.hub}"

  tags = {
    Environment = local.raw.environment
    System      = "central-observability"
    Repository  = "AWS-multi-region-observability-network"
    Stack       = "monitoring-${var.hub}"
    Owner       = "platform-infrastructure"
  }

  # Built from a name (not a resource reference) to avoid a cycle:
  # the probe needs this ARN, and the role's trust policy needs the probe's role.
  metric_writer_role_name = "${local.prefix}-probe-metrics-writer"
  metric_writer_role_arn  = "arn:aws:iam::${local.monitoring_id}:role/${local.metric_writer_role_name}"
}

# Hub account: the probe runs in the hub VPC.
provider "aws" {
  region              = local.me.region
  allowed_account_ids = [local.me.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.me.account_id}:role/${local.raw.pipeline_role_name}"
    session_name = "tf-monitoring-${var.hub}"
  }
  default_tags { tags = local.tags }
}

# Monitoring account, same region: metrics, alarms and alert topics.
provider "aws" {
  alias               = "monitoring"
  region              = local.me.region
  allowed_account_ids = [local.monitoring_id]
  assume_role {
    role_arn     = "arn:aws:iam::${local.monitoring_id}:role/${local.raw.pipeline_role_name}"
    session_name = "tf-monitoring-${var.hub}"
  }
  default_tags { tags = local.tags }
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

# -----------------------------------------------------------------------------
# Hub account: the probe
# -----------------------------------------------------------------------------
module "probe" {
  source = "../../../modules/connectivity_probe"

  name       = local.prefix
  source_hub = var.hub
  targets = [
    for k, s in local.raw.spokes : { region = k, host = s.gateway_fqdn }
  ]
  metric_regions     = distinct([for h in local.raw.hubs : h.region])
  metric_role_arn    = local.metric_writer_role_arn
  subnet_ids         = local.hub.app_subnet_ids
  security_group_ids = [local.hub.central_api_security_group_id]
  mtls_secret_arn    = var.mtls_secret_arn
}

# -----------------------------------------------------------------------------
# Monitoring account: write-only role for this hub's probe
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "writer_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [module.probe.role_arn]
    }
  }
}

data "aws_iam_policy_document" "writer" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData has no resource-level permissions
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Network/CrossRegion"]
    }
  }
}

resource "aws_iam_role" "metric_writer" {
  provider           = aws.monitoring
  name               = local.metric_writer_role_name
  assume_role_policy = data.aws_iam_policy_document.writer_trust.json
}

resource "aws_iam_role_policy" "metric_writer" {
  provider = aws.monitoring
  name     = "put-probe-metrics"
  role     = aws_iam_role.metric_writer.id
  policy   = data.aws_iam_policy_document.writer.json
}

# -----------------------------------------------------------------------------
# Monitoring account: alert topics and the full alarm matrix
# -----------------------------------------------------------------------------
module "page_topic" {
  source          = "../../../modules/alert_topic"
  providers       = { aws = aws.monitoring }
  name            = "network-connectivity-page"
  https_endpoints = var.page_endpoints
}

module "ticket_topic" {
  source          = "../../../modules/alert_topic"
  providers       = { aws = aws.monitoring }
  name            = "network-connectivity-ticket"
  https_endpoints = var.ticket_endpoints
}

module "alerting" {
  source    = "../../../modules/connectivity_alerting"
  providers = { aws = aws.monitoring }

  hubs             = keys(local.raw.hubs)
  regions          = keys(local.raw.spokes)
  page_topic_arn   = module.page_topic.topic_arn
  ticket_topic_arn = module.ticket_topic.topic_arn
  runbook_base_url = local.raw.runbook_base_url

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

# Probe Lambda errors are a hub-account metric, so this alarm lives with the probe.
resource "aws_cloudwatch_metric_alarm" "probe_errors" {
  alarm_name          = "net-SEV3-probe-${module.probe.function_name}-errors"
  alarm_description   = "Connectivity probe Lambda erroring or not running. Until fixed, hub_isolated alarms for ${var.hub} may be false positives. Runbook: ${local.raw.runbook_base_url}/net-probe"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = module.probe.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [local.hub.ticket_topic_arn]
}
