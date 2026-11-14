variable "name" { type = string }
variable "kms_key_arn" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }

locals { queues = toset(["inventory-commands", "inventory-expirations", "order-events", "catalog-events"]) }

resource "aws_sqs_queue" "dead_letter" {
  for_each                  = local.queues
  name                      = "${var.name}-${each.key}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_arn
  receive_wait_time_seconds = 20
}

resource "aws_sqs_queue" "main" {
  for_each                   = local.queues
  name                       = "${var.name}-${each.key}"
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  max_message_size           = 262144
  kms_master_key_id          = var.kms_key_arn
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dead_letter[each.key].arn, maxReceiveCount = 5 })
}

resource "aws_sqs_queue_redrive_allow_policy" "this" {
  for_each             = local.queues
  queue_url            = aws_sqs_queue.dead_letter[each.key].url
  redrive_allow_policy = jsonencode({ redrivePermission = "byQueue", sourceQueueArns = [aws_sqs_queue.main[each.key].arn] })
}

resource "aws_sqs_queue_policy" "tls" {
  for_each  = merge({ for name, queue in aws_sqs_queue.main : name => queue }, { for name, queue in aws_sqs_queue.dead_letter : "${name}-dlq" => queue })
  queue_url = each.value.url
  policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = each.value.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}

output "queues" { value = { for name, queue in aws_sqs_queue.main : name => { name = queue.name, arn = queue.arn, url = queue.url } } }
output "dead_letter_queues" { value = merge({ for name, queue in aws_sqs_queue.dead_letter : name => { name = queue.name, arn = queue.arn, url = queue.url } }, { expiry-scheduler = { name = aws_sqs_queue.scheduler_dead_letter.name, arn = aws_sqs_queue.scheduler_dead_letter.arn, url = aws_sqs_queue.scheduler_dead_letter.url } }) }
