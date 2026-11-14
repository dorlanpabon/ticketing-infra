variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "Environment must be dev, qa or prod."
  }
}
variable "account_id" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "availability_zones" { type = list(string) }
variable "image_uris" { type = map(string) }
variable "callback_urls" { type = list(string) }
variable "logout_urls" { type = list(string) }
variable "alarm_email" { type = string }
variable "monthly_budget_usd" { type = number }

locals {
  name = "ticketing-${var.environment}"
  policies = {
    dev  = { minimum = 1, maximum = 2, retention = 7, pitr = false, protect = false }
    qa   = { minimum = 1, maximum = 3, retention = 14, pitr = true, protect = false }
    prod = { minimum = 2, maximum = 6, retention = 30, pitr = true, protect = true }
  }
  policy = local.policies[var.environment]
}
