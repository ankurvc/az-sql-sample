# Setup the shared provider
provider "azurerm" {
  alias = "sharedprod"
  subscription_id = ".."
  features {}
}
# Need some data for the geo sql server
data "azurerm_resource_group" "georg" {
  count = var.env == "prod" ? 1 : 0
  name  = "rg-centralus-db"
}
data "azurerm_subnet" "geo_subnet" {
  count                = var.env == "prod" ? 1 : 0
  name                 = "snet-centralus-prod1-db"
  virtual_network_name = "vnet-centralus-prod1"
  resource_group_name  = "rg-centralus-prod"
}
# Database and resources
resource "azurerm_mssql_server" "geoserver" {
  count                        = var.env == "prod" ? 1 : 0
  name                         = var.geo_server_name
  resource_group_name          = data.azurerm_resource_group.georg[0].name
  location                     = data.azurerm_resource_group.georg[0].location
  version                      = var.db_version
  administrator_login          = var.db_admin_login
  administrator_login_password = var.db_admin_pass
  public_network_access_enabled = false

  azuread_administrator {
    login_username = var.DBA_Group_Name
    object_id      = data.azuread_group.dbas.id
    tenant_id      = var.Azure_Tenant_ID
  }

  identity { type = "SystemAssigned" }
  lifecycle { ignore_changes = [ tags, ] }
}

data "azuread_group" "geosql" {
  display_name = "Terraform SQL Servers"
}
resource "azuread_group_member" "sql_contrib_member" {
  count             = var.env == "prod" ? 1 : 0
  group_object_id   = data.azuread_group.geosql.id
  member_object_id  = azurerm_mssql_server.geoserver[0].identity.0.principal_id
}

/*
resource "azurerm_sql_firewall_rule" "geo_azure_allow" {
  count               = var.sql_public_enable == true ? 1 : 0
  name                = "AzureServices"
  resource_group_name = data.azurerm_resource_group.georg[0].name
  server_name         = azurerm_mssql_server.geoserver[0].name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}
resource "azurerm_sql_firewall_rule" "geo_internal_allow" {
  count               = var.sql_public_enable == true ? 1 : 0
  name                = "InternalAllow"
  resource_group_name = data.azurerm_resource_group.georg[0].name
  server_name         = azurerm_mssql_server.geoserver[0].name
  start_ip_address    = "10.0.0.0"
  end_ip_address      = "10.255.255.255"
}
*/

locals {
  zone_id   = [ "/subscriptions/f2a41739-c9ac-4291-b070-f2a92545c38c/resourceGroups/rg-eastus2-hub1-main/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net" ]
  sub_res   = "sqlServer"
}

# Create the private endpoint resource
resource "azurerm_private_endpoint" "geo_ep" {
  count               = var.env == "prod" ? 1 : 0
  name                = "ep-${azurerm_mssql_server.geoserver[0].name}"
  location            = data.azurerm_resource_group.georg[0].location
  resource_group_name = data.azurerm_resource_group.georg[0].name
  subnet_id           = data.azurerm_subnet.geo_subnet[0].id

  private_dns_zone_group {
    name = "privatednsgroup"
    private_dns_zone_ids = local.zone_id
  }

  private_service_connection {
    name                           = "psc-${azurerm_mssql_server.geoserver[0].name}"
    private_connection_resource_id = azurerm_mssql_server.geoserver[0].id
    subresource_names              = [ local.sub_res ]
    is_manual_connection           = false
  }
  lifecycle { ignore_changes = [ tags, ] }
}

data "azurerm_storage_account" "geo_scanstorage" {
  count               = var.env == "prod" ? 1 : 0
  provider            = azurerm.sharedprod
  name                = var.env == "prod" || var.env == "pp" ? "barsqlaucentralusprod" : "barsqlaucentralusdev"
  resource_group_name = var.env == "prod" || var.env == "pp" ? "rg-sqlaudit-prod-centralus" : "rg-sqlaudit-dev-centralus"
}

resource "azurerm_mssql_server_extended_auditing_policy" "geo_audit_policy" {
  count                                   = var.env == "prod" ? 1 : 0
  server_id                               = azurerm_mssql_server.geoserver[0].id
  storage_account_access_key              = data.azurerm_storage_account.geo_scanstorage[0].primary_access_key
  storage_account_access_key_is_secondary = true
  storage_endpoint                        = data.azurerm_storage_account.geo_scanstorage[0].primary_blob_endpoint
  retention_in_days                       = var.db_retention
  depends_on = [ azuread_group_member.sql_contrib_member ]
}
resource "azurerm_mssql_server_security_alert_policy" "geo_sqlalerts" {
  count               = var.env == "prod" ? 1 : 0
  resource_group_name = data.azurerm_resource_group.georg[0].name
  server_name         = azurerm_mssql_server.geoserver[0].name
  state               = "Enabled"
  email_addresses     = [ var.DBA_EMail ]
}
resource "azurerm_mssql_server_vulnerability_assessment" "geo_vuln" {
  count                           = var.env == "prod" ? 1 : 0
  server_security_alert_policy_id = azurerm_mssql_server_security_alert_policy.geo_sqlalerts[0].id
  storage_account_access_key      = data.azurerm_storage_account.geo_scanstorage[0].primary_access_key
  storage_container_path          = "${data.azurerm_storage_account.geo_scanstorage[0].primary_blob_endpoint}${local.Vuln_Storage_Container}/"

  recurring_scans {
    enabled                   = true
    email_subscription_admins = false
    emails = [ var.DBA_EMail ]
  }
}

### Update this for the application databases needed
data "azurerm_mssql_database" "db1" {
  count     = var.env == "prod" ? 1 : 0
  name      = "ComposeApps"
  server_id = azurerm_mssql_server.dbserver.id
}
data "azurerm_mssql_database" "db2" {
  count     = var.env == "prod" ? 1 : 0
  name      = "sqldb-baringscompose-pr"
  server_id = azurerm_mssql_server.dbserver.id
}

resource "azurerm_mssql_failover_group" "failover_group" {
  count     = var.env == "prod" ? 1 : 0
  name      = var.geo_failover_name
  server_id = azurerm_mssql_server.dbserver.id
  # Update this based on above
  databases = [ data.azurerm_mssql_database.db1[0].id, data.azurerm_mssql_database.db2[0].id ]

  partner_server {
    id = azurerm_mssql_server.geoserver[0].id
  }
  read_write_endpoint_failover_policy {
    mode          = "Manual"
  }

  lifecycle { ignore_changes = [ tags, ] }
}


// Geo Database specific variables
variable "geo_server_name" {
  type    = string
  default = null
}
variable "geo_failover_name" {
  type    = string
  default = null
}
variable "geo_db_ids" {
  type = list
  default = []
}
