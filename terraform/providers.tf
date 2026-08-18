terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # POC uses local state on purpose — simplest thing that works for a demo.
  # For anything beyond a demo, switch this to an azurerm backend
  # (state in a storage account) before more than one person touches it:
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstatefleetcart"
  #   container_name       = "tfstate"
  #   key                  = "grafana-poc.tfstate"
  # }
}

provider "azurerm" {
  features {}
}
