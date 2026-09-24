variable "name" {
  description = "Application name (short, lowercase, no spaces)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the Key Vault is created"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}

variable "purge_protection_enabled" {
  description = "Block purging the vault and its secrets while soft-deleted (irreversible once enabled; a torn-down vault then keeps its name reserved for the retention period and is recovered, not recreated, by the next apply)."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Days a deleted vault or secret stays recoverable"
  type        = number
  default     = 90

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}
