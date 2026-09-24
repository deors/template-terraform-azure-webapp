terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # azapi is used to set siteConfig.endToEndEncryptionEnabled on the Web
    # App and its slot — an attribute the azurerm provider doesn't expose
    # yet (hashicorp/terraform-provider-azurerm#25126).
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    # azuread creates the Entra app registrations behind App Service
    # authentication and the end-to-end test client.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}
