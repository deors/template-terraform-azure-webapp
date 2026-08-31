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
# The alerts are azapi_resource rather than azurerm_monitor_metric_alert.
# The alert API validates each metric name against the target's *registered*
# metric definitions, and registration is lazy: a fresh App Service Plan
# takes minutes to register CpuPercentage/MemoryPercentage, and a Web App
# registers HealthCheckStatus only once the health-check feature is probing
# a running site. Creating target and alert back-to-back therefore fails
# with 400 "Couldn't find a metric named ...". The skipMetricValidation
# criterion property does not avoid it — the service honours it for custom
# metrics only and validates platform metrics regardless — and azurerm has
# no retry hook for the 400, so each alert uses azapi's declarative retry to
# re-attempt creation while that specific error persists, bounded by the
# create timeout. A mistyped metric name fails with the same message, so an
# alert that exhausts its retries usually means the metric name is wrong for
# the target resource type — check the platform metrics reference before
# blaming timing.
# ──────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

locals {
  resource_group_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  # Retry only the metric-registration race described above; any other API
  # error still fails fast.
  alert_retry = {
    error_message_regex = ["Couldn't find a metric named"]
  }
}

resource "azapi_resource" "cpu_high" {
  type      = "Microsoft.Insights/metricAlerts@2018-03-01"
  name      = "alert-cpu-${local.prefix}"
  parent_id = local.resource_group_id
  location  = "global"
  tags      = local.base_tags
  retry     = local.alert_retry

  body = {
    properties = {
      description         = "App Service Plan CPU above ${var.alert_cpu_threshold}% (5-minute average)"
      severity            = 2
      enabled             = true
      autoMitigate        = true
      scopes              = [var.app_service_plan_id]
      evaluationFrequency = "PT1M"
      windowSize          = "PT5M"

      criteria = {
        "odata.type" = "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria"
        allOf = [
          {
            criterionType   = "StaticThresholdCriterion"
            name            = "Metric1"
            metricNamespace = "Microsoft.Web/serverfarms"
            metricName      = "CpuPercentage"
            timeAggregation = "Average"
            operator        = "GreaterThan"
            threshold       = var.alert_cpu_threshold
          }
        ]
      }
    }
  }

  timeouts {
    create = "15m"
  }
}

resource "azapi_resource" "memory_high" {
  type      = "Microsoft.Insights/metricAlerts@2018-03-01"
  name      = "alert-memory-${local.prefix}"
  parent_id = local.resource_group_id
  location  = "global"
  tags      = local.base_tags
  retry     = local.alert_retry

  body = {
    properties = {
      description         = "App Service Plan memory above ${var.alert_memory_threshold}% (5-minute average)"
      severity            = 2
      enabled             = true
      autoMitigate        = true
      scopes              = [var.app_service_plan_id]
      evaluationFrequency = "PT1M"
      windowSize          = "PT5M"

      criteria = {
        "odata.type" = "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria"
        allOf = [
          {
            criterionType   = "StaticThresholdCriterion"
            name            = "Metric1"
            metricNamespace = "Microsoft.Web/serverfarms"
            metricName      = "MemoryPercentage"
            timeAggregation = "Average"
            operator        = "GreaterThan"
            threshold       = var.alert_memory_threshold
          }
        ]
      }
    }
  }

  timeouts {
    create = "15m"
  }
}

# Availability alert. HealthCheckStatus reports the health of the instances
# behind the health check the webapp module always configures; "LessThan 1"
# fires only when no instance reports healthy — deliberately, so the alert has
# the same meaning whether the metric is emitted per instance (0/1) or as a
# healthy percentage (0–100). Caveat: metric alerts only evaluate while data
# is emitted, so a stopped (not merely unhealthy) app goes stale rather than
# firing — the post-apply verify.sh "WebApp state = Running" assertion covers
# that case instead. This is also the alert the creation retry exists for:
# HealthCheckStatus is the last metric to register, minutes after the Web App
# starts probing.
resource "azapi_resource" "health_check" {
  type      = "Microsoft.Insights/metricAlerts@2018-03-01"
  name      = "alert-health-${local.prefix}"
  parent_id = local.resource_group_id
  location  = "global"
  tags      = local.base_tags
  retry     = local.alert_retry

  body = {
    properties = {
      description         = "No Web App instance reports healthy on the health-check path (5-minute average)"
      severity            = 1
      enabled             = true
      autoMitigate        = true
      scopes              = [var.web_app_id]
      evaluationFrequency = "PT1M"
      windowSize          = "PT5M"

      criteria = {
        "odata.type" = "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria"
        allOf = [
          {
            criterionType   = "StaticThresholdCriterion"
            name            = "Metric1"
            metricNamespace = "Microsoft.Web/sites"
            metricName      = "HealthCheckStatus"
            timeAggregation = "Average"
            operator        = "LessThan"
            threshold       = 1
          }
        ]
      }
    }
  }

  timeouts {
    create = "15m"
  }
}
