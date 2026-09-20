terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.6" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.9" }
    random  = { source = "hashicorp/random", version = "~> 3.9" }
  }

  # Bootstrap runs once, locally, as a subscription Owner. Its state stays
  # local and out of git; it holds no secrets, only resource IDs.
}

provider "azurerm" {
  # Registering a namespace is a subscription-scope action and the deploy
  # identity is scoped to one resource group, so it happens here.
  resource_providers_to_register = [
    "Microsoft.Sql",
    "Microsoft.Storage",
  ]

  storage_use_azuread = true
  features {}
}

provider "azuread" {}
