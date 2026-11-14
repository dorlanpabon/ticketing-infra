variable "expected_account_id" {
  description = "AWS account explicitly approved for this environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Supply the approved twelve-digit AWS account ID."
  }
}
variable "assume_role_arn" {
  description = "Expected role already assumed by the caller (OIDC or AWS_PROFILE). Terraform does not assume it a second time."
  type        = string
  validation {
    condition     = startswith(var.assume_role_arn, "arn:aws:iam::${var.expected_account_id}:role/")
    error_message = "The assumed role must belong to expected_account_id."
  }
}
variable "region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = var.region == "us-east-1"
    error_message = "This release is qualified for us-east-1; regional expansion is a reviewed change."
  }
}
variable "image_uris" {
  description = "The three approved ECR images by immutable digest, from the release manifest."
  type        = map(string)
  validation {
    condition     = toset(keys(var.image_uris)) == toset(["catalog", "orders", "inventory"]) && alltrue([for image in values(var.image_uris) : can(regex("^${var.expected_account_id}[.]dkr[.]ecr[.]${var.region}[.]amazonaws[.]com/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$", image))])
    error_message = "Supply exactly catalog/orders/inventory ECR images in the approved account/region, each pinned by sha256 digest."
  }
}
variable "callback_urls" {
  description = "Approved HTTPS OAuth callbacks; no wildcard URLs."
  type        = list(string)
  validation {
    condition     = length(var.callback_urls) > 0 && alltrue([for url in var.callback_urls : startswith(url, "https://") && !strcontains(url, "*")])
    error_message = "At least one explicit HTTPS callback is required."
  }
}
variable "logout_urls" {
  type = list(string)
  validation {
    condition     = length(var.logout_urls) > 0 && alltrue([for url in var.logout_urls : startswith(url, "https://") && !strcontains(url, "*")])
    error_message = "At least one explicit HTTPS logout URL is required."
  }
}
variable "alarm_email" {
  description = "Authorized operations recipient; confirm its SNS subscription after deployment."
  type        = string
  validation {
    condition     = can(regex("^[^ @]+@[^ @]+[.][^ @]+$", var.alarm_email))
    error_message = "Supply the authorized notification email address."
  }
}
variable "monthly_budget_usd" {
  description = "Approved monthly budget alert threshold; alerts are not a hard spending cap."
  type        = number
  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "An explicit positive budget is required."
  }
}

variable "availability_zone_ids" {
  description = "Exactly two stable Availability Zone IDs in the approved region."
  type        = list(string)
  default     = ["use1-az1", "use1-az2"]
  validation {
    condition     = length(distinct(var.availability_zone_ids)) == 2 && alltrue([for zone in var.availability_zone_ids : can(regex("^use1-az[0-9]+$", zone))])
    error_message = "Select two distinct stable zone IDs in us-east-1."
  }
}
