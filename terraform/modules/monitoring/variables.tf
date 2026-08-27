variable "name" {
  description = "Base name for all resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging, prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "app_service_plan_id" {
  description = "Resource ID of the App Service Plan the CPU/memory alerts target"
  type        = string
}

variable "web_app_id" {
  description = "Resource ID of the Web App the health-check alert targets"
  type        = string
}

variable "log_analytics_sku" {
  description = "Log Analytics Workspace SKU"
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention_days" {
  description = "Retention period in days for Log Analytics"
  type        = number
  default     = 30
}

variable "alert_cpu_threshold" {
  description = "App Service Plan CPU percentage threshold for the high-CPU alert"
  type        = number
  default     = 70
}

variable "alert_memory_threshold" {
  description = "App Service Plan memory percentage threshold for the high-memory alert"
  type        = number
  default     = 80
}
