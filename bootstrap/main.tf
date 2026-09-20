data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "random_string" "state" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-sqlmig-tfstate"
  location = var.location
  tags     = { workload = "sql-migration-with-rollback", purpose = "terraform-state" }
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-sqlmig-lab"
  location = var.location
  tags     = { workload = "sql-migration-with-rollback", purpose = "lab" }
}

resource "azurerm_storage_account" "tfstate" {
  #checkov:skip=CKV_AZURE_59:The container is private and public blob access is disabled below.
  # This account holds Terraform state for a lab that is rebuilt from source on
  # demand. Losing it costs a re-bootstrap, not data, so LRS is the honest
  # trade rather than paying for geo-replication of disposable state.
  #checkov:skip=CKV_AZURE_206:State describes a lab rebuilt from source; LRS matches its actual value.
  # No queues are used, and blob read logging would cost more than the state it
  # watches.
  #checkov:skip=CKV_AZURE_33:No queue service is used by this account.
  #checkov:skip=CKV2_AZURE_21:Blob read logging would exceed the value of the state it records.
  #checkov:skip=CKV2_AZURE_33:A private endpoint needs a runner inside the VNet; the hosted runner is not.
  name                            = "stsqlmig${random_string.state.result}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access           = "Enabled"

  blob_properties {
    versioning_enabled = true
    delete_retention_policy { days = 7 }
  }

  tags = { workload = "sql-migration-with-rollback" }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

locals {
  # The container resource exposes a data-plane URL, which is not a valid RBAC
  # scope. Role assignments need the ARM path.
  tfstate_container_scope = "${azurerm_storage_account.tfstate.id}/blobServices/default/containers/${azurerm_storage_container.tfstate.name}"
}

# ---------------------------------------------------------------------------
# Deploy identity: federated to GitHub, no secret anywhere
# ---------------------------------------------------------------------------

resource "azuread_application" "deployer" {
  display_name     = "gh-sql-migration-with-rollback"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "deployer" {
  client_id = azuread_application.deployer.client_id
}

locals {
  # GitHub stamps immutable numeric IDs into the token, not the names. A
  # subject built from owner/repo text is accepted at creation and then fails
  # at run time with AADSTS700213, which is a confusing way to learn this.
  subject_environment = "repo:${split("/", var.github_repository)[0]}@${var.github_repository_owner_id}/${split("/", var.github_repository)[1]}@${var.github_repository_id}:environment:${var.github_environment}"
}

resource "azuread_application_federated_identity_credential" "environment" {
  #checkov:skip=CKV_AZURE_249:The subject is deliberately the immutable ID form; the checked pattern expects the name form.
  application_id = azuread_application.deployer.id
  display_name   = "github-environment-${var.github_environment}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = local.subject_environment
}

# ---------------------------------------------------------------------------
# SQL administration is a group, not a person and not a password
# ---------------------------------------------------------------------------

resource "azuread_group" "sql_admins" {
  display_name     = "sg-sqlmig-admins"
  security_enabled = true
  # The deploy identity administers the server. Humans are added by variable
  # rather than by hand, so who can reach the data stays in source control.
  members = concat([azuread_service_principal.deployer.object_id], var.extra_sql_admins)
}

# ---------------------------------------------------------------------------
# Least privilege: one resource group, plus its own state
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_lab" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deployer.object_id
}

resource "azurerm_role_assignment" "deployer_state" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.deployer.object_id
}

resource "azurerm_role_assignment" "operator_state" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
