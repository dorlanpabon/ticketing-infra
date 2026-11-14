output "api_endpoint" { value = module.identity_ingress.api_endpoint }
output "app_configuration" { value = local.app_configuration }
output "cognito" { value = { user_pool_id = module.identity_ingress.user_pool_id, client_id = module.identity_ingress.client_id, issuer = module.identity_ingress.issuer, hosted_ui_domain = module.identity_ingress.hosted_ui_domain } }
output "tables" { value = module.data.tables }
output "queues" { value = module.messaging.queues }
output "dead_letter_queues" { value = module.messaging.dead_letter_queues }
output "service_task_roles" { value = { for name, service in module.service : name => service.task_role_arn } }
output "dashboard_name" { value = module.observability.dashboard_name }
output "verification_contract" {
  value = {
    environment_policy = local.policy
    data_security      = module.data.security_contract
    ingress_security   = module.identity_ingress.security_contract
    network_access     = module.network.access_contract
    expiry_recovery    = module.messaging.expiry_recovery_contract
    services           = { for name, service in module.service : name => service.security_contract }
    worker_scaling     = { for name, service in module.service : name => service.worker_scaling_contract if local.workloads[name].role == "worker" }
  }
}
