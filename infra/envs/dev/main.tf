provider "aws" {
  region              = var.region
  allowed_account_ids = [var.expected_account_id]
  default_tags {
    tags = { Project = "ticketing", Environment = "dev", ManagedBy = "Terraform" }
  }
}

data "aws_caller_identity" "current" {}
resource "terraform_data" "identity_guard" {
  input = var.expected_account_id
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id && startswith(data.aws_caller_identity.current.arn, "arn:aws:sts::${var.expected_account_id}:assumed-role/${element(reverse(split("/", var.assume_role_arn)), 0)}/")
      error_message = "Authenticate as the explicitly approved role before running Terraform; direct IAM user credentials are rejected."
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-id"
    values = var.availability_zone_ids
  }
}

module "platform" {
  source             = "../../modules/platform"
  depends_on         = [terraform_data.identity_guard]
  environment        = "dev"
  account_id         = var.expected_account_id
  region             = var.region
  vpc_cidr           = "10.40.0.0/16"
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  image_uris         = var.image_uris
  callback_urls      = var.callback_urls
  logout_urls        = var.logout_urls
  alarm_email        = var.alarm_email
  monthly_budget_usd = var.monthly_budget_usd
}
