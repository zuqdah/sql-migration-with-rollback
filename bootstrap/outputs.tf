output "azure_client_id" {
  description = "Set as the AZURE_CLIENT_ID repository variable."
  value       = azuread_application.deployer.client_id
}

output "azure_tenant_id" {
  description = "Set as AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Set as AZURE_SUBSCRIPTION_ID."
  value       = data.azurerm_subscription.current.subscription_id
}

output "tfstate_resource_group" {
  value = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account" {
  value = azurerm_storage_account.tfstate.name
}

output "tfstate_container" {
  value = azurerm_storage_container.tfstate.name
}

output "lab_resource_group" {
  description = "Set as LAB_RESOURCE_GROUP."
  value       = azurerm_resource_group.lab.name
}

output "sql_admin_group_name" {
  description = "Set as SQL_ADMIN_GROUP_NAME."
  value       = azuread_group.sql_admins.display_name
}

output "sql_admin_group_object_id" {
  description = "Set as SQL_ADMIN_GROUP_OBJECT_ID."
  value       = azuread_group.sql_admins.object_id
}
