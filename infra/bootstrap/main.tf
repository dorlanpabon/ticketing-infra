provider "aws" {
  region              = var.region
  allowed_account_ids = [var.expected_account_id]
  default_tags {
    tags = { Project = "ticketing", Environment = var.environment, ManagedBy = "Terraform" }
  }
}

data "aws_caller_identity" "current" {}

resource "terraform_data" "identity_guard" {
  input = var.expected_account_id
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id && startswith(data.aws_caller_identity.current.arn, "arn:aws:sts::${var.expected_account_id}:assumed-role/${element(reverse(split("/", var.bootstrap_role_arn)), 0)}/")
      error_message = "Authenticate as the explicitly approved bootstrap role before running Terraform."
    }
  }
}

resource "aws_kms_key" "bootstrap" {
  description             = "${local.name} Terraform state and container registry encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = jsonencode({ Version = "2012-10-17", Statement = [{ Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.expected_account_id}:root" }, Action = "kms:*", Resource = "*" }] })
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:Terraform state is not an event source; versioning and lockfile govern recovery and concurrent writes. Review 2027-02-16.
  #checkov:skip=CKV_AWS_18:State access is restricted by IAM; organization CloudTrail is the required access audit, not recursive S3 logs. Review 2027-02-16.
  #checkov:skip=CKV_AWS_144:Cross-region state replication is an organization disaster-recovery choice; versioning is enabled. Review 2027-02-16.
  #checkov:skip=CKV2_AWS_61:State versions must not expire automatically; recovery retention requires explicit operator action. Review 2027-02-16.
  bucket        = "${local.name}-state-${var.expected_account_id}"
  force_destroy = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.bootstrap.arn
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}

resource "aws_ecr_repository" "service" {
  for_each             = toset(["catalog", "orders", "inventory"])
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.bootstrap.arn
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name
  policy     = jsonencode({ rules = [{ rulePriority = 1, description = "Remove untagged images after fourteen days; tagged releases remain available for rollback", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }, action = { type = "expire" } }] })
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "automation" {
  for_each             = toset(["plan", "apply"])
  name                 = "${local.name}-${each.key}"
  max_session_duration = 3600
  assume_role_policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = local.oidc_arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com", "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.environment}-${each.key}" } } }] })
}

resource "aws_iam_role_policy" "state" {
  for_each = aws_iam_role.automation
  role     = each.value.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.state.arn, Condition = { StringLike = { "s3:prefix" = [local.state_key, "${local.state_key}.tflock"] } } },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.state.arn}/${local.state_key}" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.state.arn}/${local.state_key}.tflock" },
    { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.bootstrap.arn, Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } } }
  ], each.key == "apply" ? [{ Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.state.arn}/${local.state_key}" }] : []) })
}

locals {
  inspect_statements = [
    { Effect = "Allow", Action = ["apigateway:GET"], Resource = ["arn:aws:apigateway:${var.region}::/apis", "arn:aws:apigateway:${var.region}::/apis/*", "arn:aws:apigateway:${var.region}::/vpclinks", "arn:aws:apigateway:${var.region}::/vpclinks/*"] },
    { Effect = "Allow", Action = ["application-autoscaling:ListTagsForResource"], Resource = ["arn:aws:application-autoscaling:${var.region}:${var.expected_account_id}:scalable-target/*"] },
    { Effect = "Allow", Action = ["budgets:ViewBudget"], Resource = ["arn:aws:budgets::${var.expected_account_id}:budget/${local.name}-monthly"] },
    { Effect = "Allow", Action = ["cloudwatch:DescribeAlarms", "cloudwatch:GetDashboard", "cloudwatch:ListTagsForResource"], Resource = ["arn:aws:cloudwatch:${var.region}:${var.expected_account_id}:alarm:${local.name}-*", "arn:aws:cloudwatch::${var.expected_account_id}:dashboard/${local.name}"] },
    { Effect = "Allow", Action = ["cognito-idp:DescribeUserPool", "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeResourceServer", "cognito-idp:GetGroup", "cognito-idp:ListTagsForResource"], Resource = ["arn:aws:cognito-idp:${var.region}:${var.expected_account_id}:userpool/*"] },
    { Effect = "Allow", Action = ["ec2:DescribeAvailabilityZones", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeVpcEndpoints", "ec2:DescribeVpcEndpointServices", "ec2:DescribePrefixLists", "ec2:DescribeFlowLogs", "ec2:DescribeNetworkInterfaces", "ecs:DescribeTaskDefinition", "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeLoadBalancerAttributes", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetGroupAttributes", "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTags", "kms:ListAliases", "logs:DescribeLogGroups", "cognito-idp:DescribeUserPoolDomain", "servicediscovery:GetOperation", "servicediscovery:ListTagsForResource", "application-autoscaling:DescribeScalableTargets", "application-autoscaling:DescribeScalingPolicies", "sns:GetSubscriptionAttributes", "route53:ListHostedZones"], Resource = ["*"] },
    { Effect = "Allow", Action = ["dynamodb:DescribeTable", "dynamodb:DescribeTimeToLive", "dynamodb:DescribeContinuousBackups", "dynamodb:ListTagsOfResource"], Resource = ["arn:aws:dynamodb:${var.region}:${var.expected_account_id}:table/${local.name}-*"] },
    { Effect = "Allow", Action = ["ec2:DescribeVpcAttribute"], Resource = ["arn:aws:ec2:${var.region}:${var.expected_account_id}:*"] },
    { Effect = "Allow", Action = ["ecs:DescribeClusters", "ecs:DescribeServices", "ecs:ListTagsForResource"], Resource = ["arn:aws:ecs:${var.region}:${var.expected_account_id}:cluster/${local.name}", "arn:aws:ecs:${var.region}:${var.expected_account_id}:service/${local.name}/*", "arn:aws:ecs:${var.region}:${var.expected_account_id}:task-definition/${local.name}-*"] },
    { Effect = "Allow", Action = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"], Resource = ["arn:aws:iam::${var.expected_account_id}:role/${local.name}-*"] },
    { Effect = "Allow", Action = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags"], Resource = ["arn:aws:kms:${var.region}:${var.expected_account_id}:key/*", "arn:aws:kms:${var.region}:${var.expected_account_id}:alias/${local.name}"] },
    { Effect = "Allow", Action = ["logs:DescribeMetricFilters", "logs:ListTagsForResource"], Resource = ["arn:aws:logs:${var.region}:${var.expected_account_id}:log-group:/ticketing/${local.name}/*"] },
    { Effect = "Allow", Action = ["route53:GetHostedZone", "route53:GetChange"], Resource = ["arn:aws:route53:::hostedzone/*", "arn:aws:route53:::change/*"] },
    { Effect = "Allow", Action = ["s3:GetBucketLocation", "s3:GetBucketPolicy", "s3:GetBucketVersioning", "s3:GetBucketPublicAccessBlock", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetBucketTagging", "s3:GetBucketAcl", "s3:GetBucketLogging", "s3:GetReplicationConfiguration", "s3:GetBucketObjectLockConfiguration", "s3:GetAccelerateConfiguration", "s3:GetBucketRequestPayment", "s3:GetBucketCORS", "s3:GetBucketWebsite"], Resource = [aws_s3_bucket.state.arn, "arn:aws:s3:::${local.name}-alb-logs-${var.expected_account_id}"] },
    { Effect = "Allow", Action = ["servicediscovery:GetNamespace", "servicediscovery:GetService"], Resource = ["arn:aws:servicediscovery:${var.region}:${var.expected_account_id}:namespace/*", "arn:aws:servicediscovery:${var.region}:${var.expected_account_id}:service/*"] },
    { Effect = "Allow", Action = ["sns:GetTopicAttributes", "sns:ListTagsForResource"], Resource = ["arn:aws:sns:${var.region}:${var.expected_account_id}:${local.name}-alarms", "arn:aws:sns:${var.region}:${var.expected_account_id}:${local.name}-alarms:*"] },
    { Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:ListQueueTags"], Resource = ["arn:aws:sqs:${var.region}:${var.expected_account_id}:${local.name}-*"] },
    { Effect = "Allow", Action = ["scheduler:GetSchedule", "scheduler:GetScheduleGroup", "scheduler:ListTagsForResource"], Resource = ["arn:aws:scheduler:${var.region}:${var.expected_account_id}:schedule/${local.name}-expiry/${local.name}-expiry-recovery", "arn:aws:scheduler:${var.region}:${var.expected_account_id}:schedule-group/${local.name}-expiry"] },
  ]
}

resource "aws_iam_policy" "inspect" {
  #checkov:skip=CKV_AWS_356:Only discovery actions without resource-level authorization use Resource *; table items, messages, object contents and secret values are excluded. Review 2027-02-16.
  for_each = { discovery = slice(local.inspect_statements, 0, 9), resources = slice(local.inspect_statements, 9, length(local.inspect_statements)) }
  name     = "${local.name}-inspect-${each.key}"
  policy   = jsonencode({ Version = "2012-10-17", Statement = each.value })
}

locals {
  provision_statements = [
    { Sid = "RegionalInfrastructure", Effect = "Allow", Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }, Action = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute", "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute", "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint", "ec2:CreateTags", "ec2:DeleteTags", "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs",
      "ecs:CreateCluster", "ecs:UpdateCluster", "ecs:UpdateClusterSettings", "ecs:DeleteCluster", "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService", "ecs:TagResource", "ecs:UntagResource",
      "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:ModifyListener", "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule", "elasticloadbalancing:SetRulePriorities", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
      "kms:CreateKey", "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:PutKeyPolicy", "kms:EnableKeyRotation", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:TagResource", "kms:UntagResource", "kms:CreateGrant", "kms:RevokeGrant", "kms:ListGrants",
      "application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget", "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy", "application-autoscaling:TagResource",
      "route53:CreateHostedZone", "route53:DeleteHostedZone", "route53:AssociateVPCWithHostedZone", "route53:ChangeResourceRecordSets", "servicediscovery:CreatePrivateDnsNamespace", "servicediscovery:DeleteNamespace", "servicediscovery:CreateService", "servicediscovery:UpdateService", "servicediscovery:DeleteService", "servicediscovery:TagResource", "servicediscovery:UntagResource",
      "cognito-idp:CreateUserPool", "cognito-idp:UpdateUserPool", "cognito-idp:DeleteUserPool", "cognito-idp:CreateUserPoolClient", "cognito-idp:UpdateUserPoolClient", "cognito-idp:DeleteUserPoolClient", "cognito-idp:CreateUserPoolDomain", "cognito-idp:UpdateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain", "cognito-idp:CreateResourceServer", "cognito-idp:UpdateResourceServer", "cognito-idp:DeleteResourceServer", "cognito-idp:CreateGroup", "cognito-idp:UpdateGroup", "cognito-idp:DeleteGroup", "cognito-idp:TagResource", "cognito-idp:UntagResource"
    ] },
    { Sid = "OwnedData", Effect = "Allow", Action = ["dynamodb:CreateTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable", "dynamodb:UpdateTimeToLive", "dynamodb:UpdateContinuousBackups", "dynamodb:TagResource", "dynamodb:UntagResource"], Resource = "arn:aws:dynamodb:${var.region}:${var.expected_account_id}:table/${local.name}-*" },
    { Sid = "OwnedQueues", Effect = "Allow", Action = ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue"], Resource = "arn:aws:sqs:${var.region}:${var.expected_account_id}:${local.name}-*" },
    { Sid = "OwnedRecoverySchedule", Effect = "Allow", Action = ["scheduler:CreateSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule", "scheduler:CreateScheduleGroup", "scheduler:DeleteScheduleGroup", "scheduler:TagResource", "scheduler:UntagResource"], Resource = ["arn:aws:scheduler:${var.region}:${var.expected_account_id}:schedule/${local.name}-expiry/${local.name}-expiry-recovery", "arn:aws:scheduler:${var.region}:${var.expected_account_id}:schedule-group/${local.name}-expiry"] },
    { Sid = "OwnedSchedulerRole", Effect = "Allow", Action = ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole"], Resource = "arn:aws:iam::${var.expected_account_id}:role/${local.name}-expiry-scheduler" },
    { Sid = "PassSchedulerRole", Effect = "Allow", Action = "iam:PassRole", Resource = "arn:aws:iam::${var.expected_account_id}:role/${local.name}-expiry-scheduler", Condition = { StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" } } },
    { Sid = "EncryptOwnedSchedule", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = "arn:aws:kms:${var.region}:${var.expected_account_id}:key/*", Condition = { StringEquals = { "aws:ResourceTag/Project" = "ticketing", "aws:ResourceTag/Environment" = var.environment, "kms:EncryptionContext:aws:scheduler:schedule:arn" = "arn:aws:scheduler:${var.region}:${var.expected_account_id}:schedule/${local.name}-expiry/${local.name}-expiry-recovery" } } },
    { Sid = "OwnedTaskRoles", Effect = "Allow", Action = ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole"], Resource = ["arn:aws:iam::${var.expected_account_id}:role/${local.name}-*-task", "arn:aws:iam::${var.expected_account_id}:role/${local.name}-*-execution", "arn:aws:iam::${var.expected_account_id}:role/${local.name}-vpc-flow"] },
    { Sid = "PassOwnedRoles", Effect = "Allow", Action = "iam:PassRole", Resource = ["arn:aws:iam::${var.expected_account_id}:role/${local.name}-*-task", "arn:aws:iam::${var.expected_account_id}:role/${local.name}-*-execution", "arn:aws:iam::${var.expected_account_id}:role/${local.name}-vpc-flow"], Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } } },
    { Sid = "ServiceLinkedRoles", Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "arn:aws:iam::${var.expected_account_id}:role/aws-service-role/*", Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "ecs.application-autoscaling.amazonaws.com", "servicediscovery.amazonaws.com"] } } },
    { Sid = "ApiGateway", Effect = "Allow", Action = ["apigateway:POST", "apigateway:PATCH", "apigateway:PUT", "apigateway:DELETE"], Resource = ["arn:aws:apigateway:${var.region}::/apis", "arn:aws:apigateway:${var.region}::/apis/*", "arn:aws:apigateway:${var.region}::/vpclinks", "arn:aws:apigateway:${var.region}::/vpclinks/*"] },
    { Sid = "OwnedLogs", Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:AssociateKmsKey", "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:TagResource", "logs:UntagResource"], Resource = "arn:aws:logs:${var.region}:${var.expected_account_id}:log-group:/ticketing/${local.name}/*" },
    { Sid = "OwnedAlarms", Effect = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"], Resource = ["arn:aws:cloudwatch:${var.region}:${var.expected_account_id}:alarm:${local.name}-*", "arn:aws:cloudwatch::${var.expected_account_id}:dashboard/${local.name}"] },
    { Sid = "OwnedNotifications", Effect = "Allow", Action = ["sns:CreateTopic", "sns:DeleteTopic", "sns:SetTopicAttributes", "sns:Subscribe", "sns:Unsubscribe", "sns:TagResource", "sns:UntagResource"], Resource = ["arn:aws:sns:${var.region}:${var.expected_account_id}:${local.name}-alarms", "arn:aws:sns:${var.region}:${var.expected_account_id}:${local.name}-alarms:*"] },
    { Sid = "OwnedBudget", Effect = "Allow", Action = "budgets:ModifyBudget", Resource = "arn:aws:budgets::${var.expected_account_id}:budget/${local.name}-monthly" },
    { Sid = "OwnedLogBucket", Effect = "Allow", Action = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration", "s3:PutBucketTagging"], Resource = "arn:aws:s3:::${local.name}-alb-logs-${var.expected_account_id}" }
  ]
}

resource "aws_iam_policy" "provision" {
  #checkov:skip=CKV_AWS_356:Creation and tag APIs require wildcard resources; regional mutations are enumerated. Data and IAM resources are scoped. Review 2027-02-16.
  for_each = { regional = slice(local.provision_statements, 0, 1), owned = slice(local.provision_statements, 1, length(local.provision_statements)) }
  name     = "${local.name}-provision-${each.key}"
  policy   = jsonencode({ Version = "2012-10-17", Statement = each.value })
}

resource "aws_iam_role_policy_attachment" "inspect" {
  for_each   = { for pair in setproduct(keys(aws_iam_role.automation), keys(aws_iam_policy.inspect)) : "${pair[0]}-${pair[1]}" => pair }
  role       = aws_iam_role.automation[each.value[0]].name
  policy_arn = aws_iam_policy.inspect[each.value[1]].arn
}

resource "aws_iam_role_policy_attachment" "provision" {
  for_each   = aws_iam_policy.provision
  role       = aws_iam_role.automation["apply"].name
  policy_arn = each.value.arn
}

output "state_bucket" { value = aws_s3_bucket.state.id }
output "state_kms_key_arn" { value = aws_kms_key.bootstrap.arn }
output "repository_urls" { value = { for service, repository in aws_ecr_repository.service : service => repository.repository_url } }
output "plan_role_arn" { value = aws_iam_role.automation["plan"].arn }
output "apply_role_arn" { value = aws_iam_role.automation["apply"].arn }
