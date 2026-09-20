terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # Registration happens in bootstrap, where Terraform runs as an Owner. The
  # deploy identity is scoped to one resource group and cannot register.
  resource_provider_registrations = "none"

  features {}
}
