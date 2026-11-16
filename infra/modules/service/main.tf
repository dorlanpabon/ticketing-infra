variable "name" { type = string }
variable "service_name" { type = string }
variable "workload_role" {
  type = string
  validation {
    condition     = contains(["api", "worker"], var.workload_role)
    error_message = "Workload role must be api or worker."
  }
}
variable "region" { type = string }
variable "account_id" { type = string }
variable "cluster_id" { type = string }
variable "cluster_name" { type = string }
variable "namespace_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "image_uri" { type = string }
variable "table_arn" { type = string }
variable "consume_queue_arns" { type = list(string) }
variable "consume_queue_names" { type = list(string) }
variable "publish_queue_arns" { type = list(string) }
variable "kms_key_arn" { type = string }
variable "log_retention_days" { type = number }
variable "min_capacity" { type = number }
variable "max_capacity" { type = number }
variable "environment" { type = map(string) }

locals {
  workload_name   = "${var.name}-${var.service_name}-${var.workload_role}"
  repository_name = split("@", join("/", slice(split("/", var.image_uri), 1, length(split("/", var.image_uri)))))[0]
  repository_arn  = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${local.repository_name}"
  assume_task     = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ecs:${var.region}:${var.account_id}:*" } } }] })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ticketing/${var.name}/${var.service_name}/${var.workload_role}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "execution" {
  name               = "${local.workload_name}-execution"
  assume_role_policy = local.assume_task
}

resource "aws_iam_role_policy" "execution" {
  #checkov:skip=CKV_AWS_356:ECR GetAuthorizationToken requires Resource *; pull and log actions are scoped separately. Review 2027-02-16.
  role = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "EcrLogin", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Sid = "PullOwnImage", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"], Resource = local.repository_arn },
    { Sid = "WriteOwnLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.this.arn}:*" }
  ] })
}

resource "aws_iam_role" "task" {
  name               = "${local.workload_name}-task"
  assume_role_policy = local.assume_task
}

resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Sid = "OwnTable", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:ConditionCheckItem", "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem", "dynamodb:Query", "dynamodb:DescribeTable"], Resource = [var.table_arn, "${var.table_arn}/index/*"] },
    { Sid = "EncryptedData", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = var.kms_key_arn, Condition = { StringEquals = { "kms:ViaService" = var.workload_role == "worker" || length(var.publish_queue_arns) > 0 ? ["sqs.${var.region}.amazonaws.com", "dynamodb.${var.region}.amazonaws.com"] : ["dynamodb.${var.region}.amazonaws.com"] } } }
    ], var.workload_role == "worker" ? [
    { Sid = "ConsumeOwnQueues", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = var.consume_queue_arns }
    ] : [], length(var.publish_queue_arns) > 0 ? [
    { Sid = "PublishDomainMessages", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = var.publish_queue_arns }
  ] : []) })
}

resource "aws_service_discovery_service" "this" {
  count = var.workload_role == "api" ? 1 : 0
  name  = var.service_name
  dns_config {
    namespace_id   = var.namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
  health_check_custom_config {}
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.workload_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume { name = "tmp" }
  container_definitions = jsonencode([{
    name                   = var.service_name
    image                  = var.image_uri
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment            = [for key in sort(keys(var.environment)) : { name = key, value = var.environment[key] }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters        = { initProcessEnabled = true, capabilities = { drop = ["ALL"] } }
    stopTimeout            = 60
    healthCheck            = { command = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/actuator/health/readiness"], interval = 30, timeout = 5, retries = 3, startPeriod = 60 }
    logConfiguration       = { logDriver = "awslogs", options = { "awslogs-group" = aws_cloudwatch_log_group.this.name, "awslogs-region" = var.region, "awslogs-stream-prefix" = var.service_name, "mode" = "non-blocking", "max-buffer-size" = "4m" } }
  }])
}

resource "aws_ecs_service" "this" {
  #checkov:skip=CKV_AWS_332:Linux Fargate 1.4.0 is explicitly pinned; redeployment receives the platform revision. Review platform upgrades before changing this version. Review 2027-02-16.
  name                               = local.workload_name
  cluster                            = var.cluster_id
  task_definition                    = aws_ecs_task_definition.this.arn
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  desired_count                      = var.min_capacity
  health_check_grace_period_seconds  = var.workload_role == "api" ? 90 : 0
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  wait_for_steady_state              = true
  propagate_tags                     = "SERVICE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }
  dynamic "load_balancer" {
    for_each = var.workload_role == "api" ? [var.target_group_arn] : []
    content {
      target_group_arn = load_balancer.value
      container_name   = var.service_name
      container_port   = 8080
    }
  }
  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this
    content { registry_arn = service_registries.value.arn }
  }
  lifecycle { ignore_changes = [desired_count] }
}

resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.workload_role == "api" ? 1 : 0
  name               = "${local.workload_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

output "service_name" { value = aws_ecs_service.this.name }
output "task_role_arn" { value = aws_iam_role.task.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.this.name }
output "task_definition_arn" { value = aws_ecs_task_definition.this.arn }
output "security_contract" {
  value = {
    public_ip         = aws_ecs_service.this.network_configuration[0].assign_public_ip
    minimum_tasks     = aws_appautoscaling_target.this.min_capacity
    maximum_tasks     = aws_appautoscaling_target.this.max_capacity
    container         = jsondecode(aws_ecs_task_definition.this.container_definitions)[0]
    task_permissions  = jsondecode(aws_iam_role_policy.task.policy)
    role              = var.workload_role
    load_balancers    = length(aws_ecs_service.this.load_balancer)
    dns_registrations = length(aws_service_discovery_service.this)
    cpu_policies      = length(aws_appautoscaling_policy.cpu)
    queue_policies    = length(aws_appautoscaling_policy.queue_scale_out) + length(aws_appautoscaling_policy.queue_scale_in)
  }
}
