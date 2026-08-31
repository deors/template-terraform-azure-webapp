output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.this.name
}

output "alert_cpu_id" {
  description = "Resource ID of the high-CPU metric alert"
  value       = azapi_resource.cpu_high.id
}

output "alert_memory_id" {
  description = "Resource ID of the high-memory metric alert"
  value       = azapi_resource.memory_high.id
}

output "alert_health_id" {
  description = "Resource ID of the health-check availability metric alert"
  value       = azapi_resource.health_check.id
}
