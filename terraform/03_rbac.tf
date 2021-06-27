# =============================================================================
# Kubernetes - Gitlab Runner - Cluster Role binding
# =============================================================================

resource "kubernetes_cluster_role_binding" "gitlab-runner-admin" {
  metadata {
    name = "gitlab-runner-admin"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.runner_namespace.metadata[0].name
  }
}
