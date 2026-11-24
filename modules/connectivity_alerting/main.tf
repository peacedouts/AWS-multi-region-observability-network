###############################################################################
# modules/connectivity_alerting  (deployed in EVERY hub region)
#
# Philosophy: raw signals do not page; correlated symptoms do.
#
# Layer 1  pair alarms        hub x region probe failure      -> no action (signal only)
# Layer 2  composite alarms   correlate the matrix:
#            region_unreachable[r]  every hub fails to reach r  -> PAGE  (regional outage / gateway down)
#            hub_isolated[h]        h fails to reach every r    -> PAGE  (hub outage; verify traffic drained)
#            path_degraded[h,r]     one path down, others fine  -> TICKET (redundant path is serving)
# Layer 3  latency alarms     p99 TCP connect above baseline  -> TICKET
#
# Probe metrics are dual-written to every hub region, so each region computes
# the same verdicts independently. Both regions notify; the incident tool
# de-duplicates on alarm name. Losing a whole region never blinds alerting.
###############################################################################

variable "hubs" {
  type        = list(string)
  description = "Hub labels, e.g. [\"use1\", \"euw1\"]."
}

variable "regions" {
  type        = list(string)
  description = "Regional spoke labels, e.g. [\"us\", \"eu\", \"ca\", \"apac\"]."
}

variable "page_topic_arn" {
  type        = string
  description = "SNS topic for SEV1/SEV2 (pages on-call)."
}

variable "ticket_topic_arn" {
  type        = string
  description = "SNS topic for SEV3 (ticket + chat, business hours)."
}

variable "runbook_base_url" {
  type        = string
  description = "Base URL for runbooks; each alarm links to <base>/<runbook-id>."
}

variable "metric_namespace" {
  type    = string
  default = "Network/CrossRegion"
}

variable "failure_periods" {
  type        = number
  default     = 3
  description = "Consecutive failed 10s windows before a pair is considered down (3 => 30s)."
}

variable "latency_p99_threshold_ms" {
  type        = map(number)
  default     = {}
  description = "Per-pair p99 TCP connect threshold keyed \"<hub>|<region>\" (set from measured baseline, ~1.5x)."
}

variable "default_latency_p99_threshold_ms" {
  type    = number
  default = 300
}

variable "local_probe_function_name" {
  type        = string
  default     = ""
  description = "This region's probe Lambda; alarms if the probe itself is broken (so a dead probe is not mistaken for a dead network)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  pairs = {
    for p in setproduct(var.hubs, var.regions) : "${p[0]}|${p[1]}" => { hub = p[0], region = p[1] }
  }

  pair_alarm_name = { for k, p in local.pairs : k => "net-pair-${p.hub}-to-${p.region}" }
}

# -----------------------------------------------------------------------------
# Layer 1: pair alarms (signal only, no actions)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "pair_down" {
  for_each = local.pairs

  alarm_name          = local.pair_alarm_name[each.key]
  alarm_description   = "Probe from hub ${each.value.hub} to regional gateway ${each.value.region} failing. Signal only; see composite alarms."
  namespace           = var.metric_namespace
  metric_name         = "ProbeSuccess"
  dimensions          = { SourceHub = each.value.hub, TargetRegion = each.value.region }
  statistic           = "Average"
  period              = 10 # high-resolution alarm
  evaluation_periods  = var.failure_periods
  datapoints_to_alarm = var.failure_periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # no data from a probe is a failure, not "OK"
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Layer 2: correlation
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_composite_alarm" "region_unreachable" {
  for_each = toset(var.regions)

  alarm_name = "net-SEV1-region-${each.key}-unreachable"
  alarm_description = join("\n", [
    "SEV1: regional gateway '${each.key}' unreachable from ALL hubs.",
    "Likely: regional outage, regional gateway/ALB down, or spoke-side route/SG/NACL change.",
    "Impact: ${each.key} events cannot be reviewed; other regions unaffected.",
    "Runbook: ${var.runbook_base_url}/net-region-unreachable",
  ])
  alarm_rule = join(" AND ", [
    for h in var.hubs : "ALARM(\"${local.pair_alarm_name["${h}|${each.key}"]}\")"
  ])
  alarm_actions = [var.page_topic_arn]
  ok_actions    = [var.page_topic_arn]
  tags          = var.tags

  depends_on = [aws_cloudwatch_metric_alarm.pair_down]
}

resource "aws_cloudwatch_composite_alarm" "hub_isolated" {
  for_each = toset(var.hubs)

  alarm_name = "net-SEV2-hub-${each.key}-isolated"
  alarm_description = join("\n", [
    "SEV2: hub '${each.key}' cannot reach ANY regional gateway.",
    "Global Accelerator health checks should already have drained it; verify, then investigate hub VPC/NAT/probe.",
    "Runbook: ${var.runbook_base_url}/net-hub-isolated",
  ])
  alarm_rule = join(" AND ", [
    for r in var.regions : "ALARM(\"${local.pair_alarm_name["${each.key}|${r}"]}\")"
  ])
  alarm_actions = [var.page_topic_arn]
  ok_actions    = [var.page_topic_arn]
  tags          = var.tags

  depends_on = [aws_cloudwatch_metric_alarm.pair_down]
}

resource "aws_cloudwatch_composite_alarm" "path_degraded" {
  for_each = local.pairs

  alarm_name = "net-SEV3-path-${each.value.hub}-to-${each.value.region}-degraded"
  alarm_description = join("\n", [
    "SEV3: single path ${each.value.hub} -> ${each.value.region} down; redundant hub is serving ${each.value.region}.",
    "No customer impact while the other path is healthy. Redundancy is reduced: fix within business hours.",
    "Likely: peering route removed, SG/NACL drift, peering connection deleted.",
    "Runbook: ${var.runbook_base_url}/net-path-degraded",
  ])
  alarm_rule = join(" AND ", [
    "ALARM(\"${local.pair_alarm_name[each.key]}\")",
    "NOT ALARM(\"${aws_cloudwatch_composite_alarm.region_unreachable[each.value.region].alarm_name}\")",
    "NOT ALARM(\"${aws_cloudwatch_composite_alarm.hub_isolated[each.value.hub].alarm_name}\")",
  ])
  alarm_actions = [var.ticket_topic_arn]
  ok_actions    = [var.ticket_topic_arn]
  tags          = var.tags
}

# -----------------------------------------------------------------------------
# Layer 3: latency regression (ticket, not page)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "pair_latency" {
  for_each = local.pairs

  alarm_name          = "net-SEV3-latency-${each.value.hub}-to-${each.value.region}"
  alarm_description   = "p99 TCP connect ${each.value.hub} -> ${each.value.region} above baseline for 15m. Runbook: ${var.runbook_base_url}/net-latency"
  namespace           = var.metric_namespace
  metric_name         = "TcpConnectMs"
  dimensions          = { SourceHub = each.value.hub, TargetRegion = each.value.region }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = lookup(var.latency_p99_threshold_ms, each.key, var.default_latency_p99_threshold_ms)
  treat_missing_data  = "notBreaching" # missing data is handled by the availability alarms
  alarm_actions       = [var.ticket_topic_arn]
  ok_actions          = [var.ticket_topic_arn]
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Watch the watcher
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "probe_errors" {
  count = var.local_probe_function_name == "" ? 0 : 1

  alarm_name          = "net-SEV3-probe-${var.local_probe_function_name}-errors"
  alarm_description   = "Connectivity probe Lambda erroring. Probe blind spot: a hub_isolated alarm may be a false positive. Runbook: ${var.runbook_base_url}/net-probe"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.local_probe_function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [var.ticket_topic_arn]
  tags                = var.tags
}

output "composite_alarm_names" {
  value = concat(
    [for a in aws_cloudwatch_composite_alarm.region_unreachable : a.alarm_name],
    [for a in aws_cloudwatch_composite_alarm.hub_isolated : a.alarm_name],
    [for a in aws_cloudwatch_composite_alarm.path_degraded : a.alarm_name],
  )
  description = "All correlation alarms."
}
