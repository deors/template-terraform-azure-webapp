locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })

  # Vault names are 3–24 chars, letters/digits/hyphens, no trailing hyphen.
  vault_name = trimsuffix(substr("kv-${local.prefix}", 0, 24), "-")
}

data "azurerm_client_config" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Key Vault
#
# Access is granted through access policies rather than Azure RBAC: policies
# are written with Contributor rights, whereas vault RBAC needs role
# assignments, which the platform's provisioning identity cannot create.
#
# The data plane stays reachable on the public endpoint because Terraform
# seeds secrets from GitHub-hosted runners, which have no fixed IP and are
# not in the VNet. Authorisation is the control, not the network.
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_key_vault" "this" {
  # checkov:skip=CKV_AZURE_109: the default network action stays Allow — Terraform writes secrets from GitHub-hosted runners with no fixed IP; access policies are the control.
  # checkov:skip=CKV_AZURE_189: same rationale as CKV_AZURE_109 — the public data plane is what the runner (and the Web App's Key Vault references) use.
  # checkov:skip=CKV2_AZURE_32: no Private Endpoint for the vault — see CKV_AZURE_109; a vault-only PE would still leave the runner outside.
  name                = local.vault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = local.base_tags

  rbac_authorization_enabled = false
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled   = true
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# The identity running Terraform seeds and rotates secrets.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}
