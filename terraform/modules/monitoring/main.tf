locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Metric alerts
#
# Azure metric alerts validate their scopes at creation, so the target
# resource IDs are passed in rather than derived from the naming convention.
# No action group is wired: routing (email, webhook, on-call) is application-
# and organisation-specific, so the alerts surface in Azure Monitor and the
# caller attaches actions out of band.
#
# Every criteria block sets skip_metric_validation. The alert API otherwise
# validates the metric name against the target's registered metric
# definitions, and a freshly created plan or app can take minutes to register
# them — so an apply that creates target and alert back-to-back intermittently
# fails with 400 "Couldn't find a metric named ...". Skipping validation
# removes that race. The trade-off: a mistyped metric name would no longer be
# rejected at apply time and would produce an alert that never fires, so any
# change to a metric_name below must be checked against the platform metrics
# reference for the target resource type.
# ──────────────────────────────────────────────────────────────────────────────

resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "alert-cpu-${local.prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_service_plan_id]
  description         = "App Service Plan CPU above ${var.alert_cpu_threshold}% (5-minute average)"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.base_tags

  criteria {
    metric_namespace = "Microsoft.Web/serverfarms"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alert_cpu_threshold

    skip_metric_validation = true
  }
}

resource "azurerm_monitor_metric_alert" "memory_high" {
  name                = "alert-memory-${local.prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_service_plan_id]
  description         = "App Service Plan memory above ${var.alert_memory_threshold}% (5-minute average)"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.base_tags

  criteria {
    metric_namespace = "Microsoft.Web/serverfarms"
    metric_name      = "MemoryPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alert_memory_threshold

    skip_metric_validation = true
  }
}

# Availability alert. HealthCheckStatus reports the health of the instances
# behind the health check the webapp module always configures; "LessThan 1"
# fires only when no instance reports healthy — deliberately, so the alert has
# the same meaning whether the metric is emitted per instance (0/1) or as a
# healthy percentage (0–100). Caveat: metric alerts only evaluate while data
# is emitted, so a stopped (not merely unhealthy) app goes stale rather than
# firing — the post-apply verify.sh "WebApp state = Running" assertion covers
# that case instead.
resource "azurerm_monitor_metric_alert" "health_check" {
  name                = "alert-health-${local.prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.web_app_id]
  description         = "No Web App instance reports healthy on the health-check path (5-minute average)"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.base_tags

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HealthCheckStatus"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1

    skip_metric_validation = true
  }
}
