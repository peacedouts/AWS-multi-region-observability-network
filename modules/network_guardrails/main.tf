###############################################################################
# modules/network_guardrails  (deployed in EVERY account/region with a VPC)
#
# Detects out-of-band changes to the connectivity layer: anything that touches
# peering, routes, SGs, NACLs or flow logs and was NOT made by the Terraform
# pipeline role. Changes by the pipeline are expected and audited via PRs;
# changes by anyone else are either an emergency fix or an incident.
#
# Prevention lives in SCPs (policies/scp/); this module is detection.
###############################################################################

variable "name" {
  type = string
}

variable "pipeline_role_arns" {
  type        = list(string)
  description = "IAM role ARNs that are allowed to change the network (Terraform deployer roles)."
}

variable "alert_topic_arn" {
  type        = string
  description = "SNS topic for security/change alerts."
}

variable "enable_config_rules" {
  type        = bool
  default     = true
  description = "Create AWS Config managed rules (requires an existing Config recorder, normally org-managed)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  watched_actions = [
    "CreateVpcPeeringConnection", "AcceptVpcPeeringConnection", "DeleteVpcPeeringConnection",
    "RejectVpcPeeringConnection", "ModifyVpcPeeringConnectionOptions",
    "CreateRoute", "ReplaceRoute", "DeleteRoute", "ReplaceRouteTableAssociation",
    "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress",
    "RevokeSecurityGroupIngress", "RevokeSecurityGroupEgress", "ModifySecurityGroupRules",
    "CreateNetworkAclEntry", "ReplaceNetworkAclEntry", "DeleteNetworkAclEntry",
    "ReplaceNetworkAclAssociation", "DeleteFlowLogs",
  ]
}

resource "aws_cloudwatch_event_rule" "out_of_band_network_change" {
  name        = "${var.name}-out-of-band-network-change"
  description = "Network change made outside the Terraform pipeline"

  # Two cases, because "anything-but" only matches when the field exists:
  #   1. assumed-role callers whose role is not a pipeline role
  #   2. IAM users and root, which have no session issuer at all
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = local.watched_actions
      "$or" = [
        {
          userIdentity = {
            type = ["AssumedRole"]
            sessionContext = {
              sessionIssuer = {
                arn = [{ "anything-but" = var.pipeline_role_arns }]
              }
            }
          }
        },
        {
          userIdentity = {
            type = ["IAMUser", "Root"]
          }
        },
      ]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "sns" {
  rule = aws_cloudwatch_event_rule.out_of_band_network_change.name
  arn  = var.alert_topic_arn

  input_transformer {
    input_paths = {
      action  = "$.detail.eventName"
      actor   = "$.detail.userIdentity.arn"
      account = "$.account"
      region  = "$.region"
      params  = "$.detail.requestParameters"
    }
    input_template = "\"Out-of-band network change: <action> by <actor> in <account>/<region>. Params: <params>. Reconcile with Terraform (plan will show drift) and confirm this was an approved break-glass change.\""
  }
}

# Continuous compliance (evidence for auditors)
resource "aws_config_config_rule" "flow_logs_enabled" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${var.name}-vpc-flow-logs-enabled"
  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }
  tags = var.tags
}

resource "aws_config_config_rule" "default_sg_closed" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${var.name}-vpc-default-sg-closed"
  source {
    owner             = "AWS"
    source_identifier = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
  }
  tags = var.tags
}

resource "aws_config_config_rule" "no_unrestricted_ingress" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${var.name}-vpc-sg-open-only-to-authorized-ports"
  source {
    owner             = "AWS"
    source_identifier = "VPC_SG_OPEN_ONLY_TO_AUTHORIZED_PORTS"
  }
  tags = var.tags
}
