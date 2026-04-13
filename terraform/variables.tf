variable "location" {
  description = "Primary Azure region for the ACR and all resources"
  type        = string
  default     = "swedencentral"
}

variable "secondary_location" {
  description = "Secondary Azure region for ACR geo-replication"
  type        = string
  default     = "westeurope"
}

variable "prefix" {
  description = "Short prefix for all resource names (lowercase alphanumeric, max 8 chars)"
  type        = string
  default     = "acrops"

  validation {
    condition     = can(regex("^[a-z0-9]{1,8}$", var.prefix))
    error_message = "Prefix must be lowercase alphanumeric, max 8 characters."
  }
}

variable "alert_email" {
  description = "Email address for alert notifications"
  type        = string
}

variable "log_analytics_retention_days" {
  description = "Number of days to retain logs in Log Analytics"
  type        = number
  default     = 30
}

variable "storage_alert_warning_gb" {
  description = "Storage threshold in GiB for warning alert (80% of Premium included = 400)"
  type        = number
  default     = 400
}

variable "storage_alert_critical_gb" {
  description = "Storage threshold in GiB for critical alert (95% of Premium included = 475)"
  type        = number
  default     = 475
}
