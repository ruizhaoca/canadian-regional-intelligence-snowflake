output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "storage_account_name" {
  value = azurerm_storage_account.landing.name
}

output "storage_account_dfs_url" {
  value = azurerm_storage_account.landing.primary_dfs_endpoint
}

output "landing_file_system" {
  value = azurerm_storage_data_lake_gen2_filesystem.landing.name
}

output "snowpipe_queue_url" {
  value = azurerm_storage_queue.snowpipe.id
}

output "snowpipe_queue_primary_uri" {
  value = "https://${azurerm_storage_account.landing.name}.queue.core.windows.net/${azurerm_storage_queue.snowpipe.name}"
}

output "container_registry_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "container_app_job_name" {
  value = try(azurerm_container_app_job.acquisition[0].name, null)
}

output "acquisition_identity_client_id" {
  value = azurerm_user_assigned_identity.acquisition.client_id
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}
