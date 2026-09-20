output "sql_server_name" {
  description = "Logical server name."
  value       = azurerm_mssql_server.this.name
}

output "sql_server_fqdn" {
  description = "Fully qualified name used by the migration."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_name" {
  description = "Target database."
  value       = azurerm_mssql_database.this.name
}

output "resource_group_name" {
  description = "Resource group holding the lab."
  value       = data.azurerm_resource_group.lab.name
}
