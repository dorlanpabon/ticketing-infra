mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/test-bootstrap/mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::ticketing-dev-state-123456789012" }
  }
}
variables {
  environment         = "dev"
  expected_account_id = "123456789012"
  bootstrap_role_arn  = "arn:aws:iam::123456789012:role/test-bootstrap"
  github_repository   = "example/ticketing-infra"
}
run "protected_bootstrap" {
  command = plan
  assert {
    condition     = alltrue([for policy in values(aws_iam_policy.provision) : length(policy.policy) <= 6144]) && alltrue([for policy in values(aws_iam_policy.inspect) : length(policy.policy) <= 6144])
    error_message = "AWS managed IAM policies must fit the 6144-character quota."
  }
  assert {
    condition     = !strcontains(jsonencode(jsondecode(aws_iam_role.automation["plan"].assume_role_policy)), "repo:*") && strcontains(aws_iam_role.automation["plan"].assume_role_policy, "repo:example/ticketing-infra:environment:dev-plan")
    error_message = "OIDC trust must identify an exact repository and environment."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.state["plan"].policy).Statement : !contains(statement.Action, "s3:PutObject") if statement.Resource == "${aws_s3_bucket.state.arn}/${local.state_key}"])
    error_message = "The plan role can write a lockfile but cannot write Terraform state."
  }
  assert {
    condition     = alltrue([for repository in values(aws_ecr_repository.service) : repository.image_tag_mutability == "IMMUTABLE"])
    error_message = "Release image tags must remain immutable."
  }
}
run "reject_repository_wildcard" {
  command = plan
  variables { github_repository = "example/*" }
  expect_failures = [var.github_repository]
}
