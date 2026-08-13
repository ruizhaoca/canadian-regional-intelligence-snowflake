output "database_name" {
  value = snowflake_database.dev.name
}

output "warehouse_name" {
  value = snowflake_warehouse.dev.name
}

output "storage_integration_name" {
  value = snowflake_storage_integration_azure.landing.name
}

output "notification_integration_name" {
  value = snowflake_notification_integration.snowpipe.name
}

output "external_stage_name" {
  value = snowflake_stage_external_azure.landing.fully_qualified_name
}
