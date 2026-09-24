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

variable "container_registry_resource_group_name" {
  description = "Resource group holding the Azure Container Registry (ACR path only). Defaults to the environment's own resource group when empty — set it for any pre-existing ACR, which will live elsewhere."
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

variable "container_port" {
  description = "TCP port the application container listens on. Default 8080; use 80 for plain placeholder images."
  type        = number
  default     = 8080
}

variable "app_settings" {
  description = "Additional application settings / environment variables"
  type        = map(string)
  default     = {}
}

variable "key_vault_secrets" {
  description = "App settings resolved from the environment's Key Vault, setting name => secret name. The secrets themselves are created outside Terraform (portal, az cli, pipeline)."
  type        = map(string)
  default     = {}
}

variable "auth_admins" {
  description = "Owners of this environment's enterprise application (user principal names or object IDs); they assign and remove users in the portal. Empty means directory administrators only."
  type        = list(string)
  default     = []
}

variable "auth_enabled" {
  description = "Enforce Microsoft Entra ID sign-in on the Web App (App Service authentication). On by default; only assigned users, groups and the end-to-end test client can access the app."
  type        = bool
  default     = true
}
