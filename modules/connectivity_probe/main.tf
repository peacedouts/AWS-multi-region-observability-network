###############################################################################
# modules/connectivity_probe  (deployed in each HUB)
#
# Active, synthetic measurement of the hub -> regional gateway path.
# VPC peering exposes no CloudWatch metrics of its own, so we measure the path
# from where the traffic actually originates.
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix, e.g. \"hub-use1\"."
}

variable "source_hub" {
  type        = string
  description = "Hub label used as the SourceHub metric dimension, e.g. \"use1\"."
}

variable "targets" {
  type = list(object({
    region = string
    host   = string
    port   = optional(number, 443)
    path   = optional(string, "/healthz")
  }))
  description = "Regional gateway endpoints to probe."
}

variable "metric_regions" {
  type        = list(string)
  description = "Regions to dual-write metrics to (every hub region), so each region can evaluate the full matrix."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Hub app-tier subnets (same as the central API)."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Use the central_api SG so the probe tests the real SG/NACL/route path."
}

variable "mtls_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager secret holding {cert,key,ca} for the probe's mTLS client identity."
}

variable "probe_interval_seconds" {
  type    = number
  default = 10
}

variable "metric_namespace" {
  type    = string
  default = "Network/CrossRegion"
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "archive_file" "probe" {
  type        = "zip"
  source_file = "${path.module}/src/probe.py"
  output_path = "${path.module}/.build/probe.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "probe" {
  name               = "${var.name}-connectivity-probe"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.probe.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "probe" {
  statement {
    sid       = "PutProbeMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level permissions
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }

  dynamic "statement" {
    for_each = var.mtls_secret_arn == "" ? [] : [1]
    content {
      sid       = "ReadProbeClientCert"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.mtls_secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "probe" {
  name   = "probe"
  role   = aws_iam_role.probe.id
  policy = data.aws_iam_policy_document.probe.json
}

resource "aws_cloudwatch_log_group" "probe" {
  name              = "/aws/lambda/${var.name}-connectivity-probe"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "probe" {
  function_name                  = "${var.name}-connectivity-probe"
  role                           = aws_iam_role.probe.arn
  runtime                        = "python3.12"
  handler                        = "probe.handler"
  filename                       = data.archive_file.probe.output_path
  source_code_hash               = data.archive_file.probe.output_base64sha256
  timeout                        = 60
  memory_size                    = 256
  reserved_concurrent_executions = 2

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = {
      SOURCE_HUB             = var.source_hub
      TARGETS                = jsonencode(var.targets)
      METRIC_REGIONS         = jsonencode(var.metric_regions)
      METRIC_NAMESPACE       = var.metric_namespace
      PROBE_INTERVAL_SECONDS = tostring(var.probe_interval_seconds)
      PROBE_WINDOW_SECONDS   = "50"
      MTLS_SECRET_ARN        = var.mtls_secret_arn
    }
  }

  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.probe, aws_iam_role_policy_attachment.vpc_access]
}

resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "${var.name}-connectivity-probe"
  schedule_expression = "rate(1 minute)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "probe" {
  rule = aws_cloudwatch_event_rule.every_minute.name
  arn  = aws_lambda_function.probe.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.probe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

output "function_name" {
  value       = aws_lambda_function.probe.function_name
  description = "Probe Lambda name (used by the probe-heartbeat alarm)."
}
