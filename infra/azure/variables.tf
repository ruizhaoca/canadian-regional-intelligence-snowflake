variable "subscription_id" {
  description = "Azure subscription ID used for the DEV deployment."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region allowed by the active subscription policy."
  type        = string
  default     = "East US"
}

variable "environment" {
  description = "Short environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "The MVP supports DEV only."
  }
}

variable "project_name" {
  description = "Short project identifier used in resource names."
  type        = string
  default     = "cri"
}

variable "container_image" {
  description = "Fully qualified ACR image. Required when enable_container_job is true."
  type        = string
  default     = null
  nullable    = true
}

variable "enable_container_job" {
  description = "Create the scheduled acquisition job after its image has been pushed to ACR."
  type        = bool
  default     = false
}

variable "acquisition_schedule" {
  description = "Five-field UTC cron schedule for the Container Apps Job."
  type        = string
  default     = "0 14 * * 1"
}

variable "snowflake_storage_principal_object_id" {
  description = "Optional Azure enterprise-app object ID from the Snowflake storage integration consent flow."
  type        = string
  default     = null
  nullable    = true
}

variable "snowflake_notification_principal_object_id" {
  description = "Optional Azure enterprise-app object ID from the Snowflake notification integration consent flow."
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default     = {}
}
