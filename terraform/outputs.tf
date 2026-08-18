output "grafana_url" {
  description = "URL to log into Grafana"
  value       = "https://${azurerm_container_app.grafana.ingress[0].fqdn}"
}

output "grafana_admin_user" {
  description = "Grafana admin username"
  value       = var.grafana_admin_user
}

output "grafana_admin_password" {
  description = "Grafana admin password (generated)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
