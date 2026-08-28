variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for all resources. No default — must be set explicitly to avoid accidental cross-region deployments."
  type        = string
}

variable "app_name" {
  description = "Application name (short, lowercase, no spaces)"
  type        = string
}

variable "container_image" {
  description = "Container image reference (repository/image:tag)"
  type        = string
}

variable "container_registry_url" {
  description = "Container registry URL (e.g. myregistry.azurecr.io). Leave empty for public Docker Hub images."
  type        = string
  default     = ""
}

variable "container_registry_username" {
  description = "Username for registries that authenticate with username + password/token (private GHCR, private Docker Hub). Leave empty for public registries and for ACR (managed identity). Inject from CI secrets, never from a tfvars file."
  type        = string
  default     = ""
}

variable "container_registry_password" {
  description = "Password or access token paired with container_registry_username. Sensitive: redacted from plan output and logs. Inject from CI secrets, never from a tfvars file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "health_check_path" {
  description = "Path the App Service health check polls. Defaults to /health. Set to / when using a placeholder container image that has no dedicated health endpoint."
  type        = string
  default     = "/health"
}

variable "app_settings" {
  description = "Additional application settings / environment variables"
  type        = map(string)
  default     = {}
}
