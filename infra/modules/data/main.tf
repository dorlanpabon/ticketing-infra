variable "name" { type = string }
variable "point_in_time_recovery" { type = bool }
variable "deletion_protection" { type = bool }
variable "kms_key_arn" { type = string }

resource "aws_dynamodb_table" "service" {
  #checkov:skip=CKV_AWS_28:DEV intentionally disables PITR; QA/PROD enable it through environment policy. Review 2027-02-16.
  for_each                    = toset(["catalog", "orders", "inventory"])
  name                        = "${var.name}-${each.key}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.deletion_protection

  dynamic "attribute" {
    for_each = toset(["pk", "sk", "gsi1pk", "gsi1sk", "gsi2pk", "gsi2sk"])
    content {
      name = attribute.value
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = toset(["gsi1", "gsi2"])
    content {
      name            = global_secondary_index.value
      projection_type = "ALL"
      key_schema {
        attribute_name = "${global_secondary_index.value}pk"
        key_type       = "HASH"
      }
      key_schema {
        attribute_name = "${global_secondary_index.value}sk"
        key_type       = "RANGE"
      }
    }
  }

  point_in_time_recovery { enabled = var.point_in_time_recovery }
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
  ttl {
    enabled        = true
    attribute_name = "ttl"
  }
}

output "tables" { value = { for name, table in aws_dynamodb_table.service : name => { name = table.name, arn = table.arn } } }
output "security_contract" {
  value = { for name, table in aws_dynamodb_table.service : name => { pitr = table.point_in_time_recovery[0].enabled, deletion_protection = table.deletion_protection_enabled } }
}
