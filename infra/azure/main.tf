data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  prefix         = "${var.project_name}-${var.environment}"
  location_token = replace(lower(var.location), " ", "")
  common_tags = merge(
    {
      environment = var.environment
      managed_by  = "terraform"
      project     = "canadian-regional-intelligence"
      owner       = "ruizhaoca"
    },
    var.tags
  )
  storage_name = "st${var.project_name}${var.environment}${random_string.suffix.result}"
  vault_name   = "kv-${local.prefix}-${random_string.suffix.result}"
  acr_name     = "acr${var.project_name}${var.environment}${random_string.suffix.result}"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}-${local.location_token}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "landing" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_data_lake_gen2_filesystem" "landing" {
  name               = "landing"
  storage_account_id = azurerm_storage_account.landing.id
}

resource "azurerm_storage_queue" "snowpipe" {
  name               = "snowpipe-notifications"
  storage_account_id = azurerm_storage_account.landing.id
}

resource "azurerm_eventgrid_system_topic" "landing" {
  name                = "evgt-${local.prefix}-landing"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  source_resource_id  = azurerm_storage_account.landing.id
  topic_type          = "Microsoft.Storage.StorageAccounts"
  tags                = local.common_tags
}

resource "azurerm_eventgrid_system_topic_event_subscription" "snowpipe" {
  name                = "evgs-${local.prefix}-snowpipe"
  system_topic        = azurerm_eventgrid_system_topic.landing.name
  resource_group_name = azurerm_resource_group.main.name

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_data_lake_gen2_filesystem.landing.name}/blobs/statcan/"
    subject_ends_with   = "/_READY.csv"
    case_sensitive      = false
  }

  advanced_filter {
    string_in {
      key = "data.api"
      values = [
        "CopyBlob",
        "FlushWithClose",
        "PutBlob",
        "PutBlockList",
        "SftpCommit",
      ]
    }
  }

  storage_queue_endpoint {
    storage_account_id = azurerm_storage_account.landing.id
    queue_name         = azurerm_storage_queue.snowpipe.name
  }

  retry_policy {
    event_time_to_live    = 1440
    max_delivery_attempts = 30
  }
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${local.prefix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.common_tags
}

resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.common_tags
}

resource "azurerm_user_assigned_identity" "acquisition" {
  name                = "id-${local.prefix}-acquisition"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "acquisition_storage" {
  scope                = azurerm_storage_account.landing.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.acquisition.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "acquisition_acr" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.acquisition.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_key_vault" "main" {
  name                       = local.vault_name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.common_tags
}

resource "azurerm_role_assignment" "acquisition_key_vault" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.acquisition.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "snowflake_storage" {
  count = var.snowflake_storage_principal_object_id == null ? 0 : 1

  scope                = azurerm_storage_account.landing.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.snowflake_storage_principal_object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "snowflake_notification" {
  count = var.snowflake_notification_principal_object_id == null ? 0 : 1

  scope                = azurerm_storage_queue.snowpipe.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = var.snowflake_notification_principal_object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_container_app_job" "acquisition" {
  count = var.enable_container_job ? 1 : 0

  name                         = "caj-${local.prefix}-acquisition"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 3600
  replica_retry_limit          = 1

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acquisition.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.acquisition.id
  }

  schedule_trigger_config {
    cron_expression          = var.acquisition_schedule
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "acquisition"
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.acquisition.client_id
      }

      env {
        name  = "AZURE_STORAGE_ACCOUNT_URL"
        value = azurerm_storage_account.landing.primary_dfs_endpoint
      }

      env {
        name  = "AZURE_STORAGE_FILE_SYSTEM"
        value = azurerm_storage_data_lake_gen2_filesystem.landing.name
      }

      env {
        name  = "AZURE_STORAGE_PREFIX"
        value = "statcan"
      }

      env {
        name  = "LOG_LEVEL"
        value = "INFO"
      }
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = !var.enable_container_job || var.container_image != null
      error_message = "container_image must be supplied when enable_container_job is true."
    }
  }

  depends_on = [
    azurerm_role_assignment.acquisition_acr,
    azurerm_role_assignment.acquisition_storage,
  ]
}
