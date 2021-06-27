# =============================================================================
# Variables - Globals
# =============================================================================

prod_project_id = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
dev_project_id  = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
region          = "fr-par"

# =============================================================================
# Variables - Infrastructures
# =============================================================================

buckets = [
  "artifacts",
  "backups",
  "dependencyproxy",
  "externaldiffs",
  "gitlfs",
  "packages",
  "registry",
  "terraformstate",
  "tmpbackups",
  "uploads"
]

nodeSelector = {
  production = "fr-par-k8s-pool-large"
}
