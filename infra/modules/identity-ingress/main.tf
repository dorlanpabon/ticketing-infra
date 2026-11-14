variable "name" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "vpc_link_security_group_id" { type = string }
variable "kms_key_arn" { type = string }
variable "log_retention_days" { type = number }
variable "deletion_protection" { type = bool }
variable "callback_urls" { type = list(string) }
variable "logout_urls" { type = list(string) }

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV2_AWS_62:Access logs are retained for investigation; object-triggered processing is not part of this system. Review 2027-02-16.
  #checkov:skip=CKV_AWS_145:ALB log delivery requires SSE-S3; state, application data, queues and logs use customer KMS keys. Review 2027-02-16.
  #checkov:skip=CKV_AWS_18:Dedicated access-log destination; recursive server access logs add no application evidence. Review 2027-02-16.
  #checkov:skip=CKV_AWS_144:Single-region demonstration; cross-region replication is explicitly out of scope. Review 2027-02-16.
  bucket        = "${var.name}-alb-logs-${var.account_id}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  #checkov:skip=CKV_AWS_145:ALB access log delivery uses SSE-S3; application and state resources use customer KMS keys. Review 2027-02-16.
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "bounded-log-retention"
    status = "Enabled"
    filter {}
    expiration { days = var.log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "LoadBalancerLogs", Effect = "Allow", Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${var.account_id}/*" },
    { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}

resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_20:Public TLS is enforced by API Gateway; its private VPC Link must not redirect to an unreachable internal HTTPS address. Review 2027-02-16.
  #checkov:skip=CKV_AWS_150:Deletion protection enabled in PROD and intentionally disabled in disposable DEV/QA. Review 2027-02-16.
  name                       = var.name
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = var.deletion_protection
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "service" {
  #checkov:skip=CKV_AWS_378:Private HTTP is the explicit demonstration boundary; end-to-end workload TLS is a documented production extension. Review 2027-02-16.
  for_each             = toset(["catalog", "orders", "inventory"])
  name                 = "${var.name}-${each.key}"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/actuator/health/readiness"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "private" {
  #checkov:skip=CKV_AWS_2:TLS terminates at API Gateway; isolated HTTP demonstration hop is documented. Review 2027-02-16.
  #checkov:skip=CKV_AWS_103:No TLS policy applies to the private HTTP listener; public API is HTTPS-only. Review 2027-02-16.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"code\":\"ROUTE_NOT_FOUND\"}"
      status_code  = "404"
    }
  }
}

locals {
  paths = {
    inventory = { priority = 10, values = ["/api/v1/events/*/tickets", "/api/v1/events/*/availability"] }
    catalog   = { priority = 20, values = ["/api/v1/events", "/api/v1/events/*"] }
    orders    = { priority = 30, values = ["/api/v1/orders", "/api/v1/orders/*", "/api/v1/admin/complimentary-orders"] }
  }
  routes = {
    "POST /api/v1/events"                       = "write"
    "GET /api/v1/events"                        = "read"
    "GET /api/v1/events/{eventId}"              = "read"
    "GET /api/v1/events/{eventId}/tickets"      = "read"
    "GET /api/v1/events/{eventId}/availability" = "read"
    "POST /api/v1/orders"                       = "write"
    "GET /api/v1/orders/{orderId}"              = "read"
    "POST /api/v1/orders/{orderId}/confirm"     = "write"
    "POST /api/v1/admin/complimentary-orders"   = "write"
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each     = local.paths
  listener_arn = aws_lb_listener.private.arn
  priority     = each.value.priority
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }
  condition {
    path_pattern { values = each.value.values }
  }
}

resource "aws_cognito_user_pool" "this" {
  #checkov:skip=CKV_AWS_280:Advanced threat protection is a paid production extension; MFA, strong passwords and admin-controlled enrollment are enabled. Review 2027-02-16.
  name                     = var.name
  mfa_configuration        = "ON"
  deletion_protection      = var.deletion_protection ? "ACTIVE" : "INACTIVE"
  auto_verified_attributes = ["email"]
  admin_create_user_config { allow_admin_create_user_only = true }
  software_token_mfa_configuration { enabled = true }
  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_group" "role" {
  for_each     = toset(["admin", "customer"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Application role checked by the owning microservice"
}

resource "aws_cognito_resource_server" "api" {
  identifier   = "ticketing"
  name         = "Ticketing API"
  user_pool_id = aws_cognito_user_pool.this.id
  scope {
    scope_name        = "read"
    scope_description = "Read authorized ticketing resources"
  }
  scope {
    scope_name        = "write"
    scope_description = "Request authorized mutations"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  name                                 = "${var.name}-public-pkce"
  user_pool_id                         = aws_cognito_user_pool.this.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "ticketing/read", "ticketing/write"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.callback_urls
  logout_urls                          = var.logout_urls
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 15
  id_token_validity                    = 15
  refresh_token_validity               = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
  depends_on = [aws_cognito_resource_server.api]
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-${var.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = var.name
  security_group_ids = [var.vpc_link_security_group_id]
  subnet_ids         = var.subnet_ids
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito"
  jwt_configuration {
    audience = [aws_cognito_user_pool_client.this.id]
    issuer   = "https://${aws_cognito_user_pool.this.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "this" {
  api_id               = aws_apigatewayv2_api.this.id
  integration_type     = "HTTP_PROXY"
  integration_uri      = aws_lb_listener.private.arn
  integration_method   = "ANY"
  connection_type      = "VPC_LINK"
  connection_id        = aws_apigatewayv2_vpc_link.this.id
  timeout_milliseconds = 10000
  request_parameters = {
    "overwrite:path"                           = "$request.path"
    "overwrite:header.X-Authenticated-Subject" = "$context.authorizer.jwt.claims.sub"
    "overwrite:header.X-Authenticated-Groups"  = "$context.authorizer.jwt.claims.cognito:groups"
    "overwrite:header.X-Request-Id"            = "$context.requestId"
  }
}

resource "aws_apigatewayv2_route" "this" {
  for_each             = local.routes
  api_id               = aws_apigatewayv2_api.this.id
  route_key            = each.key
  target               = "integrations/${aws_apigatewayv2_integration.this.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.jwt.id
  authorization_scopes = ["ticketing/${each.value}"]
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ticketing/${var.name}/ingress"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 200
    throttling_rate_limit    = 100
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format          = jsonencode({ requestId = "$context.requestId", route = "$context.routeKey", status = "$context.status", latencyMs = "$context.responseLatency", integrationStatus = "$context.integrationStatus" })
  }
}

output "target_groups" { value = { for name, target in aws_lb_target_group.service : name => target.arn } }
output "api_id" { value = aws_apigatewayv2_api.this.id }
output "api_endpoint" { value = aws_apigatewayv2_api.this.api_endpoint }
output "user_pool_id" { value = aws_cognito_user_pool.this.id }
output "client_id" { value = aws_cognito_user_pool_client.this.id }
output "issuer" { value = "https://${aws_cognito_user_pool.this.endpoint}" }
output "hosted_ui_domain" { value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com" }
output "alb_arn_suffix" { value = aws_lb.this.arn_suffix }
output "security_contract" {
  value = {
    internal_alb        = aws_lb.this.internal
    deletion_protection = aws_lb.this.enable_deletion_protection
    routes              = { for route, config in aws_apigatewayv2_route.this : route => config.authorization_type }
    identity_mapping    = aws_apigatewayv2_integration.this.request_parameters
  }
}
