locals {
  environment = "staging"

  common_tags = {
    application = var.app_name
    environment = local.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Resource Group
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.app_name}-${local.environment}"
  location = var.location
  tags     = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring (Log Analytics, metric alerts)
# ──────────────────────────────────────────────────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  name                         = var.app_name
  resource_group_name          = azurerm_resource_group.this.name
  location                     = var.location
  environment                  = local.environment
  tags                         = local.common_tags
  log_analytics_retention_days = 60

  # Metric alerts (CPU high, memory high, no healthy instance) target the
  # resources the webapp module creates. Not circular: the webapp consumes
  # only the workspace ID, the alerts consume only webapp outputs.
  app_service_plan_id = module.webapp.service_plan_id
  web_app_id          = module.webapp.web_app_id
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name                           = var.app_name
  resource_group_name            = azurerm_resource_group.this.name
  location                       = var.location
  environment                    = local.environment
  tags                           = local.common_tags
  vnet_address_space             = ["10.20.0.0/16"]
  webapp_integration_subnet_cidr = "10.20.1.0/24"
  private_endpoint_subnet_cidr   = "10.20.2.0/24"

  # Flow-log retention follows the same 30/60/90 ladder as Log Analytics
  flow_log_retention_days = 60
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
module "webapp" {
  source = "../../modules/webapp"

  name                = var.app_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  environment         = local.environment
  tags                = local.common_tags

  # Staging: P1v3 with autoscale
  sku_name = "P1v3"

  container_image        = var.container_image
  container_registry_url = var.container_registry_url
  # Registry auth is selected by what the caller provides: an *.azurecr.io URL
  # with no username pulls via the managed identity (AcrPull granted by the
  # module); a username + password/token (private GHCR, Docker Hub) pulls with
  # those credentials; anything else — public registries — pulls anonymously.
  container_registry_use_managed_identity = endswith(var.container_registry_url, ".azurecr.io") && var.container_registry_username == ""
  container_registry_username             = var.container_registry_username
  container_registry_password             = var.container_registry_password
  container_registry_resource_group_name  = var.container_registry_resource_group_name

  container_port = var.container_port
  app_settings   = var.app_settings

  # Networking – VNet integration + private endpoint, public endpoint closed.
  # Staging relies on control-plane validation rather than public HTTP smoke
  # tests; only dev opens the public endpoint (for GitHub-hosted runners).
  virtual_network_subnet_id     = module.networking.webapp_integration_subnet_id
  private_endpoint_subnet_id    = module.networking.private_endpoint_subnet_id
  private_dns_zone_id           = module.networking.webapp_private_dns_zone_id
  public_network_access_enabled = false

  # Observability
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  zone_balancing_enabled  = false
  autoscale_enabled       = true
  autoscale_min_count     = 1
  autoscale_default_count = 1
  autoscale_max_count     = 3

  # Scale out when either metric crosses its high threshold; scale in only
  # when CPU and memory are both below their low thresholds (Azure AND-s
  # scale-in rules).
  autoscale_cpu_high_threshold    = 70
  autoscale_cpu_low_threshold     = 30
  autoscale_memory_high_threshold = 80
  autoscale_memory_low_threshold  = 50

  # Staging slot for pre-swap validation
  deployment_slot_enabled = true

  health_check_path = var.health_check_path
}
