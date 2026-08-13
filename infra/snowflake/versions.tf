terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.18"
    }
  }

  backend "azurerm" {}
}

provider "snowflake" {
  role = "ACCOUNTADMIN"

  preview_features_enabled = [
    "snowflake_notification_integration_resource",
  ]

  params = {
    query_tag = "canadian-regional-intelligence:terraform"
  }
}
