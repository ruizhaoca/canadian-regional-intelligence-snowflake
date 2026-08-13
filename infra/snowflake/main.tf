locals {
  database_name  = "CRI_DEV"
  warehouse_name = "CRI_DEV_WH"
  allowed_location = format(
    "azure://%s.blob.core.windows.net/%s/%s/",
    var.azure_storage_account_name,
    var.azure_storage_file_system,
    var.azure_storage_prefix
  )
  queue_uri = format(
    "https://%s.queue.core.windows.net/%s",
    var.azure_storage_account_name,
    var.azure_snowpipe_queue_name
  )
}

resource "snowflake_resource_monitor" "dev" {
  name                      = "CRI_DEV_MONITOR"
  credit_quota              = 5
  frequency                 = "MONTHLY"
  start_timestamp           = "IMMEDIATELY"
  notify_triggers           = [50, 80]
  suspend_trigger           = 90
  suspend_immediate_trigger = 100
}

resource "snowflake_warehouse" "dev" {
  name                                = local.warehouse_name
  warehouse_type                      = "STANDARD"
  warehouse_size                      = "XSMALL"
  auto_suspend                        = 60
  auto_resume                         = true
  initially_suspended                 = true
  resource_monitor                    = snowflake_resource_monitor.dev.fully_qualified_name
  max_concurrency_level               = 8
  statement_queued_timeout_in_seconds = 60
  statement_timeout_in_seconds        = 1800
  comment                             = "X-Small DEV warehouse for Canadian Regional Intelligence."
}

resource "snowflake_database" "dev" {
  name                        = local.database_name
  data_retention_time_in_days = 1
  comment                     = "DEV database for Canadian Regional Intelligence."
}

resource "snowflake_schema" "schemas" {
  for_each = toset(["RAW", "CORE", "MART", "OPS"])

  database            = snowflake_database.dev.name
  name                = each.value
  with_managed_access = true
  comment             = "${each.value} layer managed as code."
}

resource "snowflake_account_role" "loader" {
  name    = "CRI_DEV_LOADER_ROLE"
  comment = "Owns ingestion objects and appends immutable RAW rows."
}

resource "snowflake_account_role" "transformer" {
  name    = "CRI_DEV_TRANSFORMER_ROLE"
  comment = "Owns CORE, MART, Tasks, Streams, and data-quality processing."
}

resource "snowflake_account_role" "analyst" {
  name    = "CRI_DEV_ANALYST_ROLE"
  comment = "Read-only access to published MART objects."
}

resource "snowflake_account_role" "monitor" {
  name    = "CRI_DEV_MONITOR_ROLE"
  comment = "Read-only access to operational and data-quality evidence."
}

resource "snowflake_grant_account_role" "project_roles_to_sysadmin" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
    analyst     = snowflake_account_role.analyst.name
    monitor     = snowflake_account_role.monitor.name
  }

  role_name        = each.value
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_account_role" "project_roles_to_user" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
    analyst     = snowflake_account_role.analyst.name
    monitor     = snowflake_account_role.monitor.name
  }

  role_name = each.value
  user_name = var.project_user_name
}

resource "snowflake_grant_privileges_to_account_role" "warehouse_usage" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
    analyst     = snowflake_account_role.analyst.name
    monitor     = snowflake_account_role.monitor.name
  }

  account_role_name = each.value
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.dev.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "database_usage" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
    analyst     = snowflake_account_role.analyst.name
    monitor     = snowflake_account_role.monitor.name
  }

  account_role_name = each.value
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.dev.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_raw_schema" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE", "CREATE FILE FORMAT", "CREATE PIPE", "CREATE STAGE", "CREATE TABLE"]
  on_schema {
    schema_name = snowflake_schema.schemas["RAW"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_raw_schema" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["RAW"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_execute_task" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["EXECUTE TASK"]
  on_account        = true
}

resource "snowflake_grant_privileges_to_account_role" "transformer_future_raw_tables" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["INSERT", "SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["RAW"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_future_raw_file_formats" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_schema_object {
    future {
      object_type_plural = "FILE FORMATS"
      in_schema          = snowflake_schema.schemas["RAW"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_schemas" {
  for_each = toset(["CORE", "MART", "OPS"])

  account_role_name = snowflake_account_role.transformer.name
  privileges = [
    "USAGE",
    "CREATE PROCEDURE",
    "CREATE STREAM",
    "CREATE TABLE",
    "CREATE TASK",
    "CREATE VIEW",
  ]
  on_schema {
    schema_name = snowflake_schema.schemas[each.value].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_mart_schema" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["MART"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "monitor_ops_schema" {
  account_role_name = snowflake_account_role.monitor.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["OPS"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_future_tables" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["MART"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_future_views" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.schemas["MART"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "monitor_future_tables" {
  account_role_name = snowflake_account_role.monitor.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["OPS"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "monitor_future_views" {
  account_role_name = snowflake_account_role.monitor.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.schemas["OPS"].fully_qualified_name
    }
  }
}

resource "snowflake_storage_integration_azure" "landing" {
  name                      = "CRI_DEV_AZURE_STORAGE_INT"
  enabled                   = true
  azure_tenant_id           = var.azure_tenant_id
  storage_allowed_locations = [local.allowed_location]
  comment                   = "Read-only access to immutable Statistics Canada landing batches."
}

resource "snowflake_notification_integration" "snowpipe" {
  name                            = "CRI_DEV_AZURE_QUEUE_INT"
  enabled                         = true
  notification_provider           = "AZURE_STORAGE_QUEUE"
  azure_storage_queue_primary_uri = local.queue_uri
  azure_tenant_id                 = var.azure_tenant_id
  comment                         = "Inbound Event Grid queue for Snowpipe auto-ingest."
}

resource "snowflake_stage_external_azure" "landing" {
  name                = "STATCAN_LANDING_STAGE"
  database            = snowflake_database.dev.name
  schema              = snowflake_schema.schemas["RAW"].name
  url                 = local.allowed_location
  storage_integration = snowflake_storage_integration_azure.landing.name
  comment             = "Immutable ADLS Gen2 Statistics Canada batches."
}

resource "snowflake_grant_privileges_to_account_role" "storage_integration_usage" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
  }

  account_role_name = each.value
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_storage_integration_azure.landing.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "notification_integration_usage" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_notification_integration.snowpipe.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "stage_usage" {
  for_each = {
    loader      = snowflake_account_role.loader.name
    transformer = snowflake_account_role.transformer.name
  }

  account_role_name = each.value
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STAGE"
    object_name = snowflake_stage_external_azure.landing.fully_qualified_name
  }
}
