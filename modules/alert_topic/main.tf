###############################################################################
# modules/alert_topic
#
# KMS-encrypted SNS topic that CloudWatch alarms and EventBridge rules can
# publish to. One per severity per region (e.g. "page" and "ticket"), wired to
# the incident tool (PagerDuty/Opsgenie) over HTTPS.
###############################################################################

variable "name" {
  type        = string
  description = "Topic name, e.g. \"network-page\"."
}

variable "https_endpoints" {
  type        = list(string)
  default     = []
  sensitive   = true
  description = "Incident-tool integration URLs to subscribe (PagerDuty/Opsgenie CloudWatch integration)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AlarmPublishers"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description         = "SNS ${var.name}"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms.json
  tags                = var.tags
}

resource "aws_sns_topic" "this" {
  name              = var.name
  kms_master_key_id = aws_kms_key.this.arn
  tags              = var.tags
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowAlarmPublishers"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "https" {
  # The URLs are secret; how many there are is not. Terraform refuses sensitive values in count.
  count = nonsensitive(length(var.https_endpoints))

  topic_arn              = aws_sns_topic.this.arn
  protocol               = "https"
  endpoint               = var.https_endpoints[count.index]
  endpoint_auto_confirms = true
}

output "topic_arn" {
  value       = aws_sns_topic.this.arn
  description = "SNS topic ARN."
}
