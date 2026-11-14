variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "Environment must be dev, qa or prod."
  }
}
variable "expected_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Supply the authorized AWS account ID."
  }
}
variable "bootstrap_role_arn" {
  type = string
  validation {
    condition     = startswith(var.bootstrap_role_arn, "arn:aws:iam::${var.expected_account_id}:role/")
    error_message = "Bootstrap role must belong to the approved account."
  }
}
variable "github_repository" {
  description = "Exact owner/repository of this independent infrastructure repository."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the actual owner/repository; wildcards are forbidden."
  }
}
variable "existing_github_oidc_provider_arn" {
  description = "Use the existing account-wide GitHub OIDC provider when one already exists."
  type        = string
  default     = null
}
variable "region" {
  type    = string
  default = "us-east-1"
}

locals {
  name      = "ticketing-${var.environment}"
  state_key = "ticketing/${var.environment}/terraform.tfstate"
  oidc_arn  = var.existing_github_oidc_provider_arn == null ? aws_iam_openid_connect_provider.github[0].arn : var.existing_github_oidc_provider_arn
}
