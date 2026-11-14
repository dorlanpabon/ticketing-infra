variable "name" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "kms_key_arn" { type = string }
variable "alarm_email" { type = string }
variable "monthly_budget_usd" { type = number }
variable "api_id" { type = string }
variable "queues" { type = map(object({ name = string, arn = string, url = string })) }
variable "dead_letter_queues" { type = map(object({ name = string, arn = string, url = string })) }
variable "log_groups" { type = map(string) }

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alarms.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:DeleteTopic", "sns:Subscribe", "sns:ListSubscriptionsByTopic", "sns:Publish"], Resource = aws_sns_topic.alarms.arn },
    { Sid = "CloudWatchAlarmDelivery", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish", Resource = aws_sns_topic.alarms.arn, Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:cloudwatch:${var.region}:${var.account_id}:alarm:${var.name}-*" } } }
  ] })
}

resource "aws_cloudwatch_metric_alarm" "dead_letter" {
  for_each            = var.dead_letter_queues
  alarm_name          = "${var.name}-${each.key}-dead-letter"
  alarm_description   = "A message requires investigation; replay must preserve its business identifier."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = each.value.name }
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each            = var.queues
  alarm_name          = "${var.name}-${each.key}-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 60
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = each.value.name }
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

locals {
  signals = merge(
    { for service, group in var.log_groups : "${service}_outbox_age_seconds" => { service = service, group = group, metric = "outbox_age_seconds", threshold = 30 } },
    { inventory_expiration_lag_seconds = { service = "inventory", group = var.log_groups["inventory"], metric = "expiration_lag_seconds", threshold = 5 } }
  )
}

resource "aws_cloudwatch_log_metric_filter" "business" {
  for_each       = local.signals
  name           = each.key
  log_group_name = each.value.group
  pattern        = "{ $.metric = \"${each.value.metric}\" && $.value = * }"
  metric_transformation {
    name      = each.key
    namespace = "Ticketing/${var.environment}"
    value     = "$.value"
    unit      = "Seconds"
  }
}

resource "aws_cloudwatch_metric_alarm" "business" {
  for_each            = local.signals
  alarm_name          = "${var.name}-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = aws_cloudwatch_log_metric_filter.business[each.key].metric_transformation[0].name
  namespace           = "Ticketing/${var.environment}"
  period              = 60
  statistic           = "Maximum"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "${var.name}-http-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "HTTP 5xx percentage"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      metric_name = "5xx"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiId = var.api_id }
    }
  }
  metric_query {
    id = "requests"
    metric {
      metric_name = "Count"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiId = var.api_id }
    }
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = [
    { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = { title = "Oldest queued message", region = var.region, period = 60, stat = "Maximum", metrics = [for queue in values(var.queues) : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", queue.name]] } },
    { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = { title = "Dead-letter messages", region = var.region, period = 60, stat = "Maximum", metrics = [for queue in values(var.dead_letter_queues) : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", queue.name]] } },
    { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = { title = "API latency", region = var.region, period = 60, stat = "p95", metrics = [["AWS/ApiGateway", "Latency", "ApiId", var.api_id]] } },
    { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = { title = "Outbox and expiration delay", region = var.region, period = 60, stat = "Maximum", metrics = [for signal in keys(local.signals) : ["Ticketing/${var.environment}", signal]] } }
  ] })
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alarm_email]
  }
}

output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.this.dashboard_name }
