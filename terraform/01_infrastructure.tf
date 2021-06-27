# =============================================================================
# Scaleway - Project
# =============================================================================

# No API available yet for datasource project from ID
locals {
  project_id = terraform.workspace == "production" ? var.prod_project_id : var.dev_project_id
  region     = var.region
  common_tags = [
    "environment=${terraform.workspace}",
    "platform=example",
    "service=gitlab"
  ]
}

# =============================================================================
# Scaleway - Gitlab - Object Storage Buckets
# =============================================================================

resource "random_id" "buckets" {
  for_each = toset(var.buckets)
  keepers  = { bucket = each.value }

  byte_length = 2
  prefix      = "fr-par-oss-gitlab-${each.value}-"
}

resource "scaleway_object_bucket" "buckets" {
  for_each = toset(var.buckets)

  name   = random_id.buckets[each.value].hex
  acl    = "private"
  region = local.region
}

# =============================================================================
# Scaleway - Gitlab - PostgreSQL Storage
# =============================================================================

resource "scaleway_rdb_instance" "gitlab_postgresql" {
  name           = "fr-par-rdb-gitlab-postgresql"
  node_type      = "db-dev-s"
  engine         = "PostgreSQL-12"
  is_ha_cluster  = true
  disable_backup = false
  region         = local.region
  tags           = local.common_tags
  project_id     = local.project_id

  # lifecycle { prevent_destroy = true }
}

resource "random_password" "gitlab_rdb_password" {
  length  = 32
  special = true
}

resource "scaleway_rdb_user" "gitlab_user" {
  instance_id = scaleway_rdb_instance.gitlab_postgresql.id
  name        = "gitlab"
  password    = random_password.gitlab_rdb_password.result
  is_admin    = false
}

resource "null_resource" "gitlab_db" {
  triggers = {
    instance_id = scaleway_rdb_instance.gitlab_postgresql.id,
    username    = scaleway_rdb_user.gitlab_user.name
  }
  depends_on = [scaleway_rdb_instance.gitlab_postgresql]

  # Create database
  provisioner "local-exec" {
    command     = "scw rdb database create region=fr-par instance-id=${split("/", self.triggers.instance_id)[1]} name=${self.triggers.username}"
    interpreter = ["/bin/bash", "-c"]
  }

  # Grant privilege access to the user
  provisioner "local-exec" {
    command     = <<EOF
    scw rdb privilege set region=fr-par \
    instance-id=${split("/", self.triggers.instance_id)[1]} \
    database-name=${self.triggers.username} \
    user-name=${self.triggers.username} \
    permission=all \
    && sleep 5
    EOF
    interpreter = ["/bin/bash", "-c"]
  }

  # Destroy database when destroy the user
  provisioner "local-exec" {
    when        = destroy
    command     = "scw rdb database delete region=fr-par instance-id=${split("/", self.triggers.instance_id)[1]} name=${self.triggers.username}"
    interpreter = ["/bin/bash", "-c"]
  }
}

# =============================================================================
# Wait
# =============================================================================

resource "time_sleep" "wait_build_infra" {
  depends_on = [
    scaleway_rdb_user.gitlab_user,
    scaleway_object_bucket.buckets
  ]
  create_duration = "15s"
}
