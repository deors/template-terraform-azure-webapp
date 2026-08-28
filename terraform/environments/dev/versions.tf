terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # azapi is used for preview Azure attributes that hashicorp/azurerm
    # doesn't expose yet (currently: App Service end-to-end encryption,
    # tracked at hashicorp/terraform-provider-azurerm#25126).
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  # All other backend values are injected at init time via -backend-config flags.
  # Run scripts/bootstrap-tfstate.sh from the workshop-platform-eng repository first.
  backend "azurerm" {
    # The state storage account is created with shared-key access disabled, so
    # the backend must authenticate against the blob data plane with Azure AD
    # (locally: the az login identity; in CI: OIDC via ARM_USE_AZUREAD). Needs
    # the Storage Blob Data Contributor role on the state storage account.
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}
