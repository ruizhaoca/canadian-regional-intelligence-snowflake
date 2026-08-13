variable "azure_tenant_id" {
  description = "Microsoft Entra tenant ID containing the Azure storage account."
  type        = string
}

variable "project_user_name" {
  description = "Existing Snowflake user that receives the four project roles."
  type        = string
}

variable "azure_storage_account_name" {
  description = "ADLS Gen2 account created by the Azure Terraform stack."
  type        = string
}

variable "azure_storage_file_system" {
  description = "ADLS Gen2 file system containing immutable landing batches."
  type        = string
  default     = "landing"
}

variable "azure_storage_prefix" {
  description = "Allowed landing prefix inside the file system."
  type        = string
  default     = "statcan"
}

variable "azure_snowpipe_queue_name" {
  description = "Azure Queue Storage queue receiving Event Grid notifications."
  type        = string
  default     = "snowpipe-notifications"
}
