# =============================================================================
# Variables - Globals
# =============================================================================

variable "prod_project_id" { type = string }
variable "dev_project_id" { type = string }
variable "region" { type = string }
variable "domain" { type = string }
# SCW access key to give the permission to gitlab to use OS buckets
variable "scw_bucket_access_key" {}
variable "scw_bucket_secret_key" {}
# SMTP vars from gitlab env
variable "smtp_address" {}
variable "smtp_port" {}
variable "smtp_username" {}
variable "smtp_password" {}

# =============================================================================
# Variables - Infrastructures
# =============================================================================

# bucket_list
variable "buckets" { type = list(string) }
variable "nodeSelector" { type = map(string) }
