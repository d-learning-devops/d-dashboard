# =====================================================================
# Self-Hosted Grafana on Azure Container Apps — POC
# Terraform equivalent of deploy.sh
# =====================================================================

data "azurerm_client_config" "current" {}

resource "random_password" "grafana_admin" {
  length      = 16
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 1
}

resource "random_integer" "storage_suffix" {
  min = 10000
  max = 99999
}

# ---------- 1. Resource group ----------
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

# ---------- 2. Log Analytics workspace ----------
resource "azurerm_log_analytics_workspace" "this" {
  name                = var.law_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ---------- 3. Container Apps Environment ----------
resource "azurerm_container_app_environment" "this" {
  name                       = var.cae_name
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
}

# ---------- 4. Storage account + file share for Grafana persistence ----------
resource "azurerm_storage_account" "this" {
  name                     = "${var.storage_account_prefix}${random_integer.storage_suffix.result}"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  account_tier            = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
}

# NOTE: intentionally using the (deprecated but still supported)
# storage_account_name attribute here rather than storage_account_id —
# there's an open provider bug where storage_share_id built from an
# account referenced via storage_account_id fails downstream directory/
# file resources with a "domain suffix" parsing error. This avoids it.
resource "azurerm_storage_share" "grafana_data" {
  name                 = var.file_share_name
  storage_account_name = azurerm_storage_account.this.name
  quota                = 5 # GB — plenty for a POC's sqlite db + plugins
}

resource "azurerm_storage_share_directory" "provisioning" {
  name             = "provisioning"
  storage_share_id = azurerm_storage_share.grafana_data.id
}

resource "azurerm_storage_share_directory" "datasources" {
  name             = "provisioning/datasources"
  storage_share_id = azurerm_storage_share.grafana_data.id
  depends_on       = [azurerm_storage_share_directory.provisioning]
}

resource "azurerm_storage_share_directory" "dashboards_dir" {
  name             = "provisioning/dashboards"
  storage_share_id = azurerm_storage_share.grafana_data.id
  depends_on       = [azurerm_storage_share_directory.provisioning]
}

# ---------- 5. Upload provisioning files ----------
resource "azurerm_storage_share_file" "datasources_yaml" {
  name             = "datasources.yaml"
  storage_share_id = azurerm_storage_share.grafana_data.id
  path             = azurerm_storage_share_directory.datasources.name
  source           = "${var.provisioning_dir}/datasources.yaml"

  # Re-upload if the local file changes
  content_md5 = filemd5("${var.provisioning_dir}/datasources.yaml")
}

resource "azurerm_storage_share_file" "dashboards_yaml" {
  name             = "dashboards.yaml"
  storage_share_id = azurerm_storage_share.grafana_data.id
  path             = azurerm_storage_share_directory.dashboards_dir.name
  source           = "${var.provisioning_dir}/dashboards.yaml"
  content_md5      = filemd5("${var.provisioning_dir}/dashboards.yaml")
}

resource "azurerm_storage_share_file" "starter_dashboard" {
  name             = "fleetcart-overview.json"
  storage_share_id = azurerm_storage_share.grafana_data.id
  path             = azurerm_storage_share_directory.dashboards_dir.name
  source           = "${var.provisioning_dir}/fleetcart-overview.json"
  content_md5      = filemd5("${var.provisioning_dir}/fleetcart-overview.json")
}

# ---------- 6. Register the file share as Container Apps environment storage ----------
resource "azurerm_container_app_environment_storage" "grafana_data" {
  name                         = "grafana-storage"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.grafana_data.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

# ---------- 7. Grafana Container App ----------
resource "azurerm_container_app" "grafana" {
  name                         = var.grafana_app_name
  resource_group_name         = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  secret {
    name  = "grafana-admin-password"
    value = random_password.grafana_admin.result
  }

  template {
    min_replicas = 1
    # Keep at 1 — Grafana here uses its default SQLite backend, which
    # doesn't support multiple replicas writing concurrently. Move to a
    # Postgres/MySQL backend before scaling past 1.
    max_replicas = 1

    container {
      name   = var.grafana_app_name
      image  = var.grafana_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "GF_SECURITY_ADMIN_USER"
        value = var.grafana_admin_user
      }
      env {
        name        = "GF_SECURITY_ADMIN_PASSWORD"
        secret_name = "grafana-admin-password"
      }
      env {
        name  = "GF_INSTALL_PLUGINS"
        value = "yesoreyeram-infinity-datasource,grafana-azure-monitor-datasource"
      }
      env {
        name  = "GF_AZURE_MANAGED_IDENTITY_ENABLED"
        value = "true"
      }
      env {
        name  = "GF_PATHS_PROVISIONING"
        value = "/var/lib/grafana/provisioning"
      }

      volume_mounts {
        name = "grafana-data-vol"
        path = "/var/lib/grafana"
      }
    }

    volume {
      name         = "grafana-data-vol"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.grafana_data.name
    }
  }

  ingress {
    external_enabled = true
    target_port       = 3000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [
    azurerm_storage_share_file.datasources_yaml,
    azurerm_storage_share_file.dashboards_yaml,
    azurerm_storage_share_file.starter_dashboard,
  ]
}

# ---------- 8. Grant Grafana's managed identity read access to Azure Monitor ----------
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_container_app.grafana.identity[0].principal_id
}
