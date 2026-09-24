output "id" {
  description = "Resource ID of the Key Vault. Depends on the deployer access policy so secret writes in other modules never race it."
  value       = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

output "name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Data-plane URI of the Key Vault"
  value       = azurerm_key_vault.this.vault_uri
}
