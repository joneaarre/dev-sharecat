##############################################################################
## ICD PostgreSQL
##############################################################################
resource "ibm_database" "icd_postgresql" {
  name              = "${var.prefix}-postgres"
  service           = "databases-for-postgres"
  plan              = var.icd_postgres_plan
  version           = var.icd_postgres_db_version
  service_endpoints = var.icd_postgres_service_endpoints
  location          = var.region
  resource_group_id = ibm_resource_group.resource_group.id
  tags              = var.tags

  # Encrypt DB (comment to use IBM-provided Automatic Key)
  key_protect_instance      = ibm_resource_instance.key-protect.id
  key_protect_key           = ibm_kp_key.key.id
  backup_encryption_key_crn = ibm_kp_key.key.id
  depends_on = [ 
    # require when using encryption key otherwise provisioning failed
    ibm_iam_authorization_policy.postgres-kms,
  ]

  # DB Settings
  adminpassword                = var.icd_postgres_adminpassword
  members_memory_allocation_mb = 3072  # 1GB  per member
  members_disk_allocation_mb   = 61440 # 20GB per member
  # users {
  #   name     = "user123"
  #   password = "password12"
  # }
  # whitelist {
  #   address     = "172.168.1.1/32"
  #   description = "desc"
  # }
}

# VPE can only be created once PosgreSQL DB is fully registered in the backend
resource "time_sleep" "wait_for_postgres_initialization" {
  # count = tobool(var.use_vpe) ? 1 : 0

  depends_on = [
    ibm_database.icd_postgres
  ]

  create_duration = "5m"
}

# VPE (Virtual Private Endpoint) for PostgreSQL
##############################################################################
# Make sure your Cloud Databases deployment's private endpoint is enabled
# otherwise you'll face this error: "Service does not support VPE extensions."
##############################################################################
resource "ibm_is_virtual_endpoint_gateway" "vpe_postgres" {
  name           = "${var.prefix}-postgres-vpe"
  resource_group = ibm_resource_group.resource_group.id
  vpc            = ibm_is_vpc.vpc.id

  target {
    crn           = ibm_database.icd_postgres.id
    resource_type = "provider_cloud_service"
  }

  # one Reserved IP for per zone in the VPC
  dynamic "ips" {
    for_each = { for subnet in ibm_is_subnet.subnet : subnet.id => subnet }
    content {
      subnet = ips.key
      name   = "${ips.value.name}-ip"
    }
  }

  depends_on = [
    time_sleep.wait_for_postgres_initialization
  ]

  tags = var.tags
}

data "ibm_is_virtual_endpoint_gateway_ips" "postgres_vpe_ips" {
  gateway = ibm_is_virtual_endpoint_gateway.vpe_postgres.id
}

output "postgres_vpe_ips" {
  value = data.ibm_is_virtual_endpoint_gateway_ips.postgres_vpe_ips
}
