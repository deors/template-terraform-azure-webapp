terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # azapi is used for the metric alerts so their creation can retry while
    # the target's metric definitions register (see the comment block in
    # main.tf) — azurerm_monitor_metric_alert has no retry hook for that.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}
