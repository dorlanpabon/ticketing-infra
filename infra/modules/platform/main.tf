resource "aws_kms_key" "this" {
  description             = "${local.name} encryption for application data, queues and logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" },
    { Sid = "CloudWatchLogs", Effect = "Allow", Principal = { Service = "logs.${var.region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/ticketing/${local.name}/*" } } },
    { Sid = "CloudWatchAlarms", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = ["kms:Decrypt", "kms:GenerateDataKey*"], Resource = "*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } }
  ] })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}

module "network" {
  source             = "../network"
  name               = local.name
  cidr               = var.vpc_cidr
  region             = var.region
  availability_zones = var.availability_zones
  log_retention_days = local.policy.retention
  kms_key_arn        = aws_kms_key.this.arn
}

module "data" {
  source                 = "../data"
  name                   = local.name
  point_in_time_recovery = local.policy.pitr
  deletion_protection    = local.policy.protect
  kms_key_arn            = aws_kms_key.this.arn
}

module "messaging" {
  source      = "../messaging"
  name        = local.name
  kms_key_arn = aws_kms_key.this.arn
  account_id  = var.account_id
  region      = var.region
}

module "identity_ingress" {
  source                     = "../identity-ingress"
  name                       = local.name
  region                     = var.region
  account_id                 = var.account_id
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.subnet_ids
  alb_security_group_id      = module.network.alb_security_group_id
  vpc_link_security_group_id = module.network.vpc_link_security_group_id
  kms_key_arn                = aws_kms_key.this.arn
  log_retention_days         = local.policy.retention
  deletion_protection        = local.policy.protect
  callback_urls              = var.callback_urls
  logout_urls                = var.logout_urls
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "${local.name}.internal"
  vpc  = module.network.vpc_id
}

locals {
  contexts = ["catalog", "orders", "inventory"]
  workloads = {
    catalog-api      = { context = "catalog", role = "api" }
    catalog-worker   = { context = "catalog", role = "worker" }
    orders-api       = { context = "orders", role = "api" }
    orders-worker    = { context = "orders", role = "worker" }
    inventory-api    = { context = "inventory", role = "api" }
    inventory-worker = { context = "inventory", role = "worker" }
  }
  consume = { catalog = ["catalog-events"], orders = ["order-events"], inventory = ["inventory-commands", "inventory-expirations"] }
  publish = { catalog = ["inventory-commands"], orders = ["inventory-commands"], inventory = ["inventory-expirations", "order-events", "catalog-events"] }
  base_app_configuration = {
    for service in local.contexts : service => merge({
      APP_ENV                                   = var.environment
      SPRING_PROFILES_ACTIVE                    = "aws"
      AWS_REGION                                = var.region
      DYNAMODB_TABLE_NAME                       = module.data.tables[service].name
      INVENTORY_COMMANDS_QUEUE_URL              = module.messaging.queues["inventory-commands"].url
      INVENTORY_EXPIRATIONS_QUEUE_URL           = module.messaging.queues["inventory-expirations"].url
      ORDER_EVENTS_QUEUE_URL                    = module.messaging.queues["order-events"].url
      CATALOG_EVENTS_QUEUE_URL                  = module.messaging.queues["catalog-events"].url
      INVENTORY_BASE_URL                        = "http://inventory.${aws_service_discovery_private_dns_namespace.this.name}:8080"
      AUTH_MODE                                 = "trusted-gateway"
      SERVER_PORT                               = "8080"
      MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE = "health,info"
      MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED = "true"
      MANAGEMENT_ENDPOINT_HEALTH_SHOW_DETAILS   = "never"
      LOGGING_STRUCTURED_FORMAT_CONSOLE         = "ecs"
      JAVA_TOOL_OPTIONS                         = "-XX:MaxRAMPercentage=65.0 -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp"
      }, service == "inventory" ? {} : { OUTBOX_POLL_INTERVAL_MS = "500" },
      service == "orders" ? { RECONCILIATION_INTERVAL_MS = "5000" } : {}
    )
  }
  app_configuration = {
    for name, workload in local.workloads : name => merge(local.base_app_configuration[workload.context], {
      APP_ROLE        = workload.role
      API_ENABLED     = tostring(workload.role == "api")
      WORKERS_ENABLED = tostring(workload.role == "worker")
    })
  }
}

module "service" {
  for_each            = local.workloads
  source              = "../service"
  name                = local.name
  service_name        = each.value.context
  workload_role       = each.value.role
  region              = var.region
  account_id          = var.account_id
  cluster_id          = aws_ecs_cluster.this.id
  cluster_name        = aws_ecs_cluster.this.name
  namespace_id        = aws_service_discovery_private_dns_namespace.this.id
  subnet_ids          = module.network.subnet_ids
  security_group_id   = module.network.service_security_group_ids[each.key]
  target_group_arn    = each.value.role == "api" ? module.identity_ingress.target_groups[each.value.context] : null
  image_uri           = var.image_uris[each.value.context]
  table_arn           = module.data.tables[each.value.context].arn
  consume_queue_arns  = [for queue in local.consume[each.value.context] : module.messaging.queues[queue].arn]
  consume_queue_names = [for queue in local.consume[each.value.context] : module.messaging.queues[queue].name]
  publish_queue_arns  = [for queue in local.publish[each.value.context] : module.messaging.queues[queue].arn if each.value.role == "worker" || each.value.context == "orders"]
  kms_key_arn         = aws_kms_key.this.arn
  log_retention_days  = local.policy.retention
  min_capacity        = local.policy.minimum
  max_capacity        = local.policy.maximum
  environment         = local.app_configuration[each.key]
  depends_on          = [module.identity_ingress]
}

module "observability" {
  source             = "../observability"
  name               = local.name
  account_id         = var.account_id
  region             = var.region
  environment        = var.environment
  kms_key_arn        = aws_kms_key.this.arn
  alarm_email        = var.alarm_email
  monthly_budget_usd = var.monthly_budget_usd
  api_id             = module.identity_ingress.api_id
  queues             = module.messaging.queues
  dead_letter_queues = module.messaging.dead_letter_queues
  log_groups         = { for context in local.contexts : context => module.service["${context}-worker"].log_group_name }
}
