resource "aws_scheduler_schedule_group" "expiry" {
  name = "${var.name}-expiry"
}

resource "aws_sqs_queue" "scheduler_dead_letter" {
  name                      = "${var.name}-expiry-scheduler-dlq"
  message_retention_seconds = 1209600
  receive_wait_time_seconds = 20
  kms_master_key_id         = var.kms_key_arn
  redrive_allow_policy      = jsonencode({ redrivePermission = "denyAll" })
}

resource "aws_sqs_queue_policy" "scheduler_dead_letter_tls" {
  queue_url = aws_sqs_queue.scheduler_dead_letter.url
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.scheduler_dead_letter.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}

resource "aws_iam_role" "expiry_scheduler" {
  name = "${var.name}-expiry-scheduler"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = aws_scheduler_schedule_group.expiry.arn } }
  }] })
}

resource "aws_iam_role_policy" "expiry_scheduler" {
  name = "deliver-expiry-recovery"
  role = aws_iam_role.expiry_scheduler.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "DeliverRecovery", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.main["inventory-expirations"].arn, aws_sqs_queue.scheduler_dead_letter.arn] },
    { Sid = "EncryptedQueues", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = var.kms_key_arn, Condition = { StringEquals = { "kms:ViaService" = "sqs.${var.region}.amazonaws.com" } } },
    { Sid = "DecryptSchedule", Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_key_arn, Condition = { StringEquals = { "kms:EncryptionContext:aws:scheduler:schedule:arn" = "arn:aws:scheduler:${var.region}:${var.account_id}:schedule/${aws_scheduler_schedule_group.expiry.name}/${var.name}-expiry-recovery" } } }
  ] })
}

resource "aws_scheduler_schedule" "expiry_recovery" {
  name                         = "${var.name}-expiry-recovery"
  group_name                   = aws_scheduler_schedule_group.expiry.name
  description                  = "Recovery sweep only; per-reservation SQS delayed messages are the primary timer."
  schedule_expression          = "rate(1 minute)"
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"
  kms_key_arn                  = var.kms_key_arn
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sqs_queue.main["inventory-expirations"].arn
    role_arn = aws_iam_role.expiry_scheduler.arn
    input = jsonencode({
      messageId     = "<aws.scheduler.execution-id>"
      type          = "SweepExpiredReservations"
      schemaVersion = 1
      aggregateId   = "inventory-expiry"
      correlationId = "<aws.scheduler.execution-id>"
      causationId   = "scheduler"
      occurredAt    = "<aws.scheduler.scheduled-time>"
      payload       = {}
    })
    retry_policy {
      maximum_event_age_in_seconds = 120
      maximum_retry_attempts       = 2
    }
    dead_letter_config { arn = aws_sqs_queue.scheduler_dead_letter.arn }
  }
  depends_on = [aws_iam_role_policy.expiry_scheduler]
}

output "expiry_recovery_contract" {
  value = {
    expression      = aws_scheduler_schedule.expiry_recovery.schedule_expression
    flexible_window = aws_scheduler_schedule.expiry_recovery.flexible_time_window[0].mode
    target          = aws_scheduler_schedule.expiry_recovery.target[0].arn
    envelope        = jsondecode(aws_scheduler_schedule.expiry_recovery.target[0].input)
    maximum_age     = aws_scheduler_schedule.expiry_recovery.target[0].retry_policy[0].maximum_event_age_in_seconds
    retries         = aws_scheduler_schedule.expiry_recovery.target[0].retry_policy[0].maximum_retry_attempts
    delivery_dlq    = aws_scheduler_schedule.expiry_recovery.target[0].dead_letter_config[0].arn
    trust           = jsondecode(aws_iam_role.expiry_scheduler.assume_role_policy)
    permissions     = jsondecode(aws_iam_role_policy.expiry_scheduler.policy)
  }
}
