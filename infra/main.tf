data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false

  keepers = {
    # Azure reserves a SQL server name against the region it was first created
    # in, and keeps the reservation even when that creation failed. Moving the
    # server to another region therefore has to move it to another name, or
    # the create fails with InvalidResourceLocation against a resource that
    # does not appear in the resource group at all.
    location = coalesce(var.location, data.azurerm_resource_group.lab.location)
  }
}

locals {
  name     = "sqlmig-${random_string.suffix.result}"
  location = coalesce(var.location, data.azurerm_resource_group.lab.location)

  tags = merge(var.tags, {
    workload   = "sql-migration-with-rollback"
    managed-by = "terraform"
    repo       = "github.com/zuqdah/sql-migration-with-rollback"
  })
}

# ---------------------------------------------------------------------------
# The logical server. No SQL login is ever created: Entra is the only way in,
# so there is no password to leak, rotate, or find in a pipeline log.
# ---------------------------------------------------------------------------

resource "azurerm_mssql_server" "this" {
  # GitHub-hosted runners sit in no VNet of ours, so a private endpoint would
  # make this server unreachable by the only thing that needs it. The server is
  # created with no firewall rules at all; the migration opens a pinhole for
  # its own address and closes it in the same run, so the exposure lasts
  # minutes rather than being a standing allow-list entry.
  #checkov:skip=CKV_AZURE_113:Private access would break the hosted runner that performs the migration; exposure is a per-run pinhole instead.
  #checkov:skip=CKV2_AZURE_45:Same constraint; a private endpoint needs a runner inside the VNet.
  # Auditing writes to a storage account that would outlive the database it
  # audits. This lab is destroyed after each run and keeps its evidence as
  # build artifacts instead: facts, assessment, parity and rollback reports.
  #checkov:skip=CKV_AZURE_23:Evidence is retained as build artifacts; the audited database does not survive the run.
  #checkov:skip=CKV_AZURE_24:Retention cannot exceed the lifetime of a database that is dropped the same day.
  #checkov:skip=CKV2_AZURE_2:Vulnerability assessment needs a storage account and a recurring scan; the server exists for minutes.
  name                          = "sql-${local.name}"
  resource_group_name           = data.azurerm_resource_group.lab.name
  location                      = local.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  azuread_administrator {
    login_username              = var.sql_admin_group_name
    object_id                   = var.sql_admin_group_object_id
    azuread_authentication_only = true
  }
}

# Deliberately no firewall rules here. The migration workflow opens a pinhole
# for the runner's own address and closes it in the same run, so the server is
# never left reachable from anywhere between deployments.

resource "azurerm_mssql_database" "this" {
  #checkov:skip=CKV_AZURE_229:Zone redundancy doubles cost for a lab that exists for minutes.
  #checkov:skip=CKV_AZURE_224:Ledger is not relevant to a migration target that is rebuilt each run.
  name      = var.database_name
  server_id = azurerm_mssql_server.this.id
  collation = "SQL_Latin1_General_CP1_CI_AS"
  tags      = local.tags

  # Serverless: compute pauses when idle and bills nothing while paused, which
  # suits a database that is busy for ten minutes and then forgotten.
  sku_name                    = "GP_S_Gen5_1"
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = var.auto_pause_minutes
  max_size_gb                 = var.max_size_gb

  storage_account_type = "Local"
  zone_redundant       = false

  # The lab rebuilds this database on every run; long-term retention would
  # outlive the thing it protects.
  short_term_retention_policy {
    retention_days = 7
  }
}
