mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/test-plan/mock-session" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012", key_id = "12345678-1234-1234-1234-123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-workload" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/test-table" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:test-queue", url = "https://sqs.us-east-1.amazonaws.com/123456789012/test-queue" }
  }
  mock_resource "aws_scheduler_schedule_group" {
    defaults = { arn = "arn:aws:scheduler:us-east-1:123456789012:schedule-group/ticketing-dev-expiry" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:test-topic" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/ticketing/test" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/1234567890123456" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/test/1234567890123456/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/1234567890123456" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { id = "arn:aws:ecs:us-east-1:123456789012:cluster/test", arn = "arn:aws:ecs:us-east-1:123456789012:cluster/test" }
  }
  mock_resource "aws_service_discovery_service" {
    defaults = { arn = "arn:aws:servicediscovery:us-east-1:123456789012:service/srv-1234567890123456" }
  }
  mock_resource "aws_cognito_user_pool" {
    defaults = { id = "us-east-1_Test123", endpoint = "cognito-idp.us-east-1.amazonaws.com/us-east-1_Test123" }
  }
}

variables {
  expected_account_id = "123456789012"
  assume_role_arn     = "arn:aws:iam::123456789012:role/test-plan"
  image_uris = {
    catalog   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/ticketing/catalog@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    orders    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/ticketing/orders@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    inventory = "123456789012.dkr.ecr.us-east-1.amazonaws.com/ticketing/inventory@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
  callback_urls      = ["https://example.com/oauth/callback"]
  logout_urls        = ["https://example.com/logout"]
  alarm_email        = "operations@example.com"
  monthly_budget_usd = 25
}

run "isolated_dev_plan" {
  command = plan
  assert {
    condition     = module.platform.app_configuration["orders-api"].APP_ENV == "dev"
    error_message = "Environment configuration must be derived from this root."
  }
  assert {
    condition     = alltrue([for service in values(module.platform.verification_contract.services) : service.public_ip == false && service.minimum_tasks == 1 && service.maximum_tasks == 2 && service.container.readonlyRootFilesystem == true && service.container.user == "10001:10001"])
    error_message = "Private, non-root workloads and environment scaling limits are required."
  }
  assert {
    condition     = alltrue([for service in values(module.platform.verification_contract.services) : !strcontains(jsonencode(service.task_permissions), "dynamodb:Scan") && !strcontains(jsonencode(service.task_permissions), "sqs:*")])
    error_message = "Task roles must not scan tables or have SQS wildcard actions."
  }

  assert {
    condition     = alltrue([for table in values(module.platform.verification_contract.data_security) : table.pitr == false && table.deletion_protection == false])
    error_message = "The actual tables must implement environment recovery and deletion policies."
  }
  assert {
    condition     = module.platform.verification_contract.ingress_security.internal_alb && module.platform.verification_contract.ingress_security.deletion_protection == false && length(module.platform.verification_contract.ingress_security.routes) == 9 && alltrue([for route, auth in module.platform.verification_contract.ingress_security.routes : auth == "JWT" && !strcontains(route, "internal")])
    error_message = "Only the nine authenticated public routes may reach the private ingress."
  }

  assert {
    condition     = length(module.platform.verification_contract.services) == 6 && alltrue([for context in ["catalog", "orders", "inventory"] : module.platform.verification_contract.services["${context}-api"].container.image == module.platform.verification_contract.services["${context}-worker"].container.image])
    error_message = "Three domain images must produce six independently scalable workloads without rebuilding worker images."
  }
  assert {
    condition     = alltrue([for name, workload in module.platform.verification_contract.services : workload.role == "api" ? (workload.load_balancers == 1 && workload.dns_registrations == 1 && workload.cpu_policies == 1 && workload.queue_policies == 0 && (name == "orders-api" || !strcontains(jsonencode(workload.task_permissions), "sqs:"))) : (workload.load_balancers == 0 && workload.dns_registrations == 0 && workload.cpu_policies == 0 && workload.queue_policies == 2 && strcontains(jsonencode(workload.task_permissions), "sqs:ReceiveMessage") && strcontains(jsonencode(workload.task_permissions), "sqs:SendMessage"))])
    error_message = "APIs register with ALB/DNS and workers consume and scale on their own queues."
  }

  assert {
    condition = (
      length([for statement in module.platform.verification_contract.services["orders-api"].task_permissions.Statement : statement if anytrue([for action in statement.Action : startswith(action, "sqs:")])]) == 1 &&
      alltrue([
        for statement in module.platform.verification_contract.services["orders-api"].task_permissions.Statement :
        statement.Action == ["sqs:SendMessage"] && statement.Resource == [module.platform.queues["inventory-commands"].arn]
        if anytrue([for action in statement.Action : startswith(action, "sqs:")])
      ])
    )
    error_message = "Orders API can only send messages to the inventory commands queue."
  }
  assert {
    condition     = alltrue([for workload in values(module.platform.verification_contract.services) : ({ for entry in workload.container.environment : entry.name => entry.value }).API_ENABLED == tostring(workload.role == "api") && ({ for entry in workload.container.environment : entry.name => entry.value }).WORKERS_ENABLED == tostring(workload.role == "worker")])
    error_message = "API and worker execution flags must be mutually exclusive in the actual task definitions."
  }
  assert {
    condition     = toset(module.platform.verification_contract.network_access.alb_destinations) == toset(["catalog-api", "orders-api", "inventory-api"]) && toset(module.platform.verification_contract.network_access.inventory_callers) == toset(["orders-api", "orders-worker"])
    error_message = "Workers cannot receive ALB traffic and Orders worker must reach the Inventory API privately."
  }

  assert {
    condition = (
      length(module.platform.queues) == 4 && length(module.platform.dead_letter_queues) == 5 &&
      module.platform.verification_contract.expiry_recovery.expression == "rate(1 minute)" &&
      module.platform.verification_contract.expiry_recovery.flexible_window == "OFF" &&
      module.platform.verification_contract.expiry_recovery.target == module.platform.queues["inventory-expirations"].arn &&
      module.platform.verification_contract.expiry_recovery.envelope.type == "SweepExpiredReservations" &&
      module.platform.verification_contract.expiry_recovery.envelope.schemaVersion == 1 &&
      module.platform.verification_contract.expiry_recovery.maximum_age == 120 &&
      module.platform.verification_contract.expiry_recovery.retries == 2 &&
      module.platform.verification_contract.expiry_recovery.delivery_dlq == module.platform.dead_letter_queues["expiry-scheduler"].arn
    )
    error_message = "Recovery must target the separate expiry queue once per minute with a bounded retry policy and delivery DLQ."
  }
  assert {
    condition = (
      module.platform.verification_contract.expiry_recovery.trust.Statement[0].Condition.StringEquals["aws:SourceAccount"] == var.expected_account_id &&
      module.platform.verification_contract.expiry_recovery.trust.Statement[0].Condition.ArnEquals["aws:SourceArn"] == "arn:aws:scheduler:us-east-1:123456789012:schedule-group/ticketing-dev-expiry" &&
      module.platform.verification_contract.expiry_recovery.permissions.Statement[0].Action == ["sqs:SendMessage"] &&
      length(module.platform.verification_contract.expiry_recovery.permissions.Statement[0].Resource) == 2 &&
      length([for statement in module.platform.verification_contract.services["inventory-worker"].task_permissions.Statement : statement if statement.Sid == "ConsumeOwnQueues"][0].Resource) == 2
    )
    error_message = "Scheduler trust must be tied to this account/group and Inventory must consume both business and expiry queues."
  }
  assert {
    condition = alltrue([for worker in values(module.platform.verification_contract.worker_scaling) :
      worker.out_alarms[0].threshold == 32 && worker.in_alarms[0].evaluation_periods == 5 &&
      worker.out_policies[0].step_scaling_policy_configuration[0].cooldown == 60 &&
      worker.in_policies[0].step_scaling_policy_configuration[0].cooldown == 300
    ]) && length(module.platform.verification_contract.worker_scaling["inventory-worker"].out_alarms[0].metric_query) == 3 && length(module.platform.verification_contract.worker_scaling["inventory-worker"].in_alarms[0].metric_query) == 5
    error_message = "Worker scaling must preserve thresholds/cooldowns and account for both Inventory queues before scaling in."
  }
}
run "reject_other_account_role" {
  command = plan
  variables { assume_role_arn = "arn:aws:iam::999999999999:role/other-account" }
  expect_failures = [var.assume_role_arn]
}
run "reject_mutable_images" {
  command = plan
  variables { image_uris = { catalog = "example:latest", orders = "example:latest", inventory = "example:latest" } }
  expect_failures = [var.image_uris]
}
run "reject_plain_http_callback" {
  command = plan
  variables { callback_urls = ["http://example.com/oauth/callback"] }
  expect_failures = [var.callback_urls]
}
