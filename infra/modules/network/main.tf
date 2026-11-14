variable "name" { type = string }
variable "cidr" { type = string }
variable "region" { type = string }
variable "availability_zones" { type = list(string) }
variable "log_retention_days" { type = number }
variable "kms_key_arn" { type = string }

locals {
  workloads = {
    catalog-api      = { context = "catalog", role = "api" }
    catalog-worker   = { context = "catalog", role = "worker" }
    orders-api       = { context = "orders", role = "api" }
    orders-worker    = { context = "orders", role = "worker" }
    inventory-api    = { context = "inventory", role = "api" }
    inventory-worker = { context = "inventory", role = "worker" }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_default_security_group" "closed" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-deny" }
}

resource "aws_subnet" "private" {
  for_each                = { for index, zone in var.availability_zones : zone => index }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.cidr, 8, each.value)
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-${each.key}-private" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "vpc_link" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_apigatewayv2_vpc_link in identity-ingress through an explicit module output. Review 2027-02-16.
  name_prefix = "${var.name}-vpc-link-"
  description = "API Gateway VPC Link; only the private ingress is reachable"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_lb in identity-ingress through an explicit module output. Review 2027-02-16.
  name_prefix = "${var.name}-ingress-"
  description = "Internal ALB reached exclusively through API Gateway"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "service" {
  #checkov:skip=CKV2_AWS_5:Each group is attached to its aws_ecs_service through the platform module. Review 2027-02-16.
  for_each    = local.workloads
  name_prefix = "${var.name}-${each.key}-"
  description = "Private ${each.key} workload"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-endpoints-"
  description = "TLS access to AWS endpoints from application tasks"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP inside the private demonstration network"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_link" {
  #checkov:skip=CKV_AWS_260:Only the VPC Link security group is allowed; this rule has no CIDR or Internet source. Review 2027-02-16.
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "Only API Gateway integration can enter"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  for_each                     = { for name, group in aws_security_group.service : name => group if local.workloads[name].role == "api" }
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = each.value.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Route to application and health endpoint"
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  for_each                     = { for name, group in aws_security_group.service : name => group if local.workloads[name].role == "api" }
  security_group_id            = each.value.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Application traffic from protected ingress"
}

resource "aws_vpc_security_group_ingress_rule" "inventory_from_orders" {
  for_each                     = toset(["orders-api", "orders-worker"])
  security_group_id            = aws_security_group.service["inventory-api"].id
  referenced_security_group_id = aws_security_group.service[each.key].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Authoritative reservation lookup from Orders"
}

resource "aws_vpc_security_group_egress_rule" "orders_to_inventory" {
  for_each                     = toset(["orders-api", "orders-worker"])
  security_group_id            = aws_security_group.service[each.key].id
  referenced_security_group_id = aws_security_group.service["inventory-api"].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Authoritative reservation lookup"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_services" {
  for_each                     = aws_security_group.service
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = each.value.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "TLS from ${each.key} to AWS APIs"
}

resource "aws_vpc_security_group_egress_rule" "services_to_endpoints" {
  for_each                     = aws_security_group.service
  security_group_id            = each.value.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "TLS to private AWS endpoints"
}

resource "aws_vpc_endpoint" "gateway" {
  for_each          = toset(["s3", "dynamodb"])
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.name}-${each.key}" }
}

resource "aws_vpc_security_group_egress_rule" "services_to_gateways" {
  for_each          = { for pair in setproduct(keys(aws_security_group.service), keys(aws_vpc_endpoint.gateway)) : "${pair[0]}-${pair[1]}" => pair }
  security_group_id = aws_security_group.service[each.value[0]].id
  prefix_list_id    = aws_vpc_endpoint.gateway[each.value[1]].prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "TLS to ${each.value[1]} gateway endpoint"
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["sqs", "ecr.api", "ecr.dkr", "logs"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  tags                = { Name = "${var.name}-${each.key}" }
}

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/ticketing/${var.name}/vpc-flow"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "flow" {
  name               = "${var.name}-vpc-flow"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "flow" {
  role   = aws_iam_role.flow.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.flow.arn}:*" }] })
}

resource "aws_flow_log" "this" {
  iam_role_arn    = aws_iam_role.flow.arn
  log_destination = aws_cloudwatch_log_group.flow.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.this.id
}

output "vpc_id" { value = aws_vpc.this.id }
output "subnet_ids" { value = [for subnet in aws_subnet.private : subnet.id] }
output "service_security_group_ids" { value = { for name, group in aws_security_group.service : name => group.id } }
output "alb_security_group_id" { value = aws_security_group.alb.id }
output "vpc_link_security_group_id" { value = aws_security_group.vpc_link.id }
output "access_contract" {
  value = {
    workloads         = keys(aws_security_group.service)
    alb_destinations  = keys(aws_vpc_security_group_ingress_rule.service_from_alb)
    inventory_callers = keys(aws_vpc_security_group_ingress_rule.inventory_from_orders)
  }
}
