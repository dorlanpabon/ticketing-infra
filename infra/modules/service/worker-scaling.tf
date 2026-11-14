resource "aws_appautoscaling_policy" "queue_scale_out" {
  count              = var.workload_role == "worker" ? 1 : 0
  name               = "${local.workload_name}-queue-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 128
      scaling_adjustment          = 1
    }
    step_adjustment {
      metric_interval_lower_bound = 128
      scaling_adjustment          = 2
    }
  }
}

resource "aws_appautoscaling_policy" "queue_scale_in" {
  count              = var.workload_role == "worker" ? 1 : 0
  name               = "${local.workload_name}-queue-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_scale_out" {
  count               = var.workload_role == "worker" ? 1 : 0
  alarm_name          = "${local.workload_name}-scaling-backlog"
  alarm_description   = "Add one worker at 32 queued messages, two at 160, within the environment capacity bounds."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 32
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.queue_scale_out[0].arn]
  metric_query {
    id          = "backlog"
    expression  = "SUM([${join(",", [for index, name in var.consume_queue_names : "v${index}"])}])"
    label       = "Visible messages across owned queues"
    return_data = true
  }
  dynamic "metric_query" {
    for_each = { for index, name in var.consume_queue_names : "v${index}" => name }
    content {
      id = metric_query.key
      metric {
        metric_name = "ApproximateNumberOfMessagesVisible"
        namespace   = "AWS/SQS"
        period      = 60
        stat        = "Maximum"
        dimensions  = { QueueName = metric_query.value }
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_scale_in" {
  count               = var.workload_role == "worker" ? 1 : 0
  alarm_name          = "${local.workload_name}-scaling-idle"
  alarm_description   = "Remove one worker only after five minutes with no visible or in-flight messages; minimum capacity stays active for outbox and timers."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.queue_scale_in[0].arn]
  metric_query {
    id          = "backlog"
    expression  = "SUM([${join(",", flatten([for index, name in var.consume_queue_names : ["v${index}", "n${index}"]]))}])"
    label       = "Visible and in-flight messages"
    return_data = true
  }
  dynamic "metric_query" {
    for_each = { for index, name in var.consume_queue_names : "v${index}" => name }
    content {
      id = metric_query.key
      metric {
        metric_name = "ApproximateNumberOfMessagesVisible"
        namespace   = "AWS/SQS"
        period      = 60
        stat        = "Maximum"
        dimensions  = { QueueName = metric_query.value }
      }
    }
  }
  dynamic "metric_query" {
    for_each = { for index, name in var.consume_queue_names : "n${index}" => name }
    content {
      id = metric_query.key
      metric {
        metric_name = "ApproximateNumberOfMessagesNotVisible"
        namespace   = "AWS/SQS"
        period      = 60
        stat        = "Maximum"
        dimensions  = { QueueName = metric_query.value }
      }
    }
  }
}

output "worker_scaling_contract" {
  value = {
    out_alarms   = aws_cloudwatch_metric_alarm.queue_scale_out
    in_alarms    = aws_cloudwatch_metric_alarm.queue_scale_in
    out_policies = aws_appautoscaling_policy.queue_scale_out
    in_policies  = aws_appautoscaling_policy.queue_scale_in
  }
}
