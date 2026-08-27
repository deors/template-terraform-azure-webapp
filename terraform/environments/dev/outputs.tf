output "web_app_name" {
  description = "Name of the provisioned Web App, used as the resource identifier in az commands"
  value       = module.webapp.web_app_name
}

output "default_hostname" {
  description = "Azure-assigned hostname (app-<name>-<env>.azurewebsites.net) for the Web App"
  value       = module.webapp.default_hostname
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity, for granting the app access to Azure services"
  value       = module.webapp.managed_identity_client_id
}

output "private_endpoint_ip" {
  description = "Private IP address the Private Endpoint resolves to inside the VNet"
  value       = module.webapp.private_endpoint_ip
}
