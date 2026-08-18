variable "resource_group_name" {
  description = "Resource group for all POC resources"
  type        = string
  default     = "rg-fleetcart-grafana-poc"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "law_name" {
  description = "Log Analytics workspace name (required by the Container Apps environment)"
  type        = string
  default     = "law-fleetcart-poc"
}

variable "cae_name" {
  description = "Container Apps Environment name"
  type        = string
  default     = "cae-fleetcart-poc"
}

variable "storage_account_prefix" {
  description = "Prefix for the storage account name; a random suffix is appended since storage account names must be globally unique"
  type        = string
  default     = "stfleetcart"
}

variable "file_share_name" {
  description = "Azure File Share name backing Grafana's persistent volume"
  type        = string
  default     = "grafana-data"
}

variable "grafana_app_name" {
  description = "Container App name for Grafana"
  type        = string
  default     = "grafana-poc"
}

variable "grafana_image" {
  description = "Grafana OSS container image"
  type        = string
  default     = "grafana/grafana-oss:11.2.0"
}

variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "provisioning_dir" {
  description = "Local path to the provisioning files (datasources.yaml, dashboards.yaml, dashboard JSON)"
  type        = string
  default     = "../provisioning"
}
