terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# Random suffix to ensure ACR name is globally unique.
# ACR names must be alphanumeric, 5-50 chars, globally unique across Azure.
resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  upper   = false
}
