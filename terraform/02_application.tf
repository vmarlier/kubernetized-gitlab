# =============================================================================
# Getting the k8s datasource
# =============================================================================

data "terraform_remote_state" "k8s" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket                      = "fr-par-p-oss-tfstate-do-not-delete"
    key                         = "landingzone/infrastructure-socle.tfstate"
    region                      = "fr-par"
    endpoint                    = "https://s3.fr-par.scw.cloud"
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}

# =============================================================================
# Kubernetes - Providers Configuration
# =============================================================================

provider "kubernetes" {
  host                   = data.terraform_remote_state.k8s.outputs.k8s_host
  cluster_ca_certificate = data.terraform_remote_state.k8s.outputs.k8s_ca_certificate
  token                  = data.terraform_remote_state.k8s.outputs.k8s_token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.k8s.outputs.k8s_host
    cluster_ca_certificate = data.terraform_remote_state.k8s.outputs.k8s_ca_certificate
    token                  = data.terraform_remote_state.k8s.outputs.k8s_token
  }
}

# =============================================================================
# Kubernetes - Namespaces
# =============================================================================

resource "kubernetes_namespace" "namespace" {
  depends_on = [time_sleep.wait_build_infra]
  metadata { name = "gitlab" }
  timeouts { delete = "10m" }
}

resource "kubernetes_namespace" "runner_namespace" {
  depends_on = [time_sleep.wait_build_infra]
  metadata { name = "gitlab-runner" }
  timeouts { delete = "10m" }
}

# =============================================================================
# Kubernetes - Create Secrets
# =============================================================================

# Connections Secrets
resource "kubernetes_secret" "connections" {
  for_each = toset(fileset("${path.module}/configs/connections/", "*.yml"))
  metadata {
    name      = join("-", ["gitlab", split(".", each.value)[0], "storage", "config"])
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }

  data = {
    connection = templatefile(
      "${path.module}/configs/connections/${each.value}",
      {
        # Credentials
        scw_access_key = var.scw_bucket_access_key
        scw_secret_key = var.scw_bucket_secret_key
        # Buckets
        bucket_region   = local.region
        bucket_registry = scaleway_object_bucket.buckets["registry"].name
      }
    )
  }
  type = "opaque"
}

# Database Password
resource "kubernetes_secret" "gitlab-pgql-password" {
  metadata {
    name      = "gitlab-pgql-password"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
  data = { gitlab-pgql-password = scaleway_rdb_user.gitlab_user.password }
  type = "opaque"
}

# TLS certificates
resource "kubernetes_secret" "tls_secret" {
  metadata {
    name      = "tls-cert"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
  data = {
    "tls.crt" = file("${path.module}/configs/tls/cert.pem")
    "tls.key" = file("${path.module}/configs/tls/cert.key")
  }
  type = "kubernetes.io/tls"
}

# =============================================================================
# Helm - Install Gitlab
# =============================================================================

resource "helm_release" "gitlab" {
  name      = "gitlab"
  namespace = kubernetes_namespace.namespace.metadata[0].name
  timeout   = 600

  repository = "https://charts.gitlab.io/"
  chart      = "gitlab"
  version    = "4.7.1"

  set {
    name  = "nodeSelector.k8s.scaleway.com/pool-name"
    value = data.terraform_remote_state.k8s.outputs.k8s_pool_names.large.name
  }

  values = [for file in fileset("${path.module}/configs/gitlab/", "*.yml") :
    templatefile("${path.module}/configs/gitlab/${file}",
      {
        # Base
        gitlab_version   = "13.7.3"
        cron_enabled     = terraform.workspace == "production" ? "true" : "false"
        worker_processes = terraform.workspace == "production" ? 2 : 1
        memory_request   = terraform.workspace == "production" ? "2.5G" : "1.25G"
        memory_limits    = terraform.workspace == "production" ? "3G" : "1.5G"
        # Credentials
        scw_access_key = var.scw_bucket_access_key
        scw_secret_key = var.scw_bucket_secret_key
        # Buckets
        bucket_region          = local.region
        bucket_artifacts       = scaleway_object_bucket.buckets["artifacts"].name
        bucket_backups         = scaleway_object_bucket.buckets["backups"].name
        bucket_dependencyproxy = scaleway_object_bucket.buckets["dependencyproxy"].name
        bucket_externaldiffs   = scaleway_object_bucket.buckets["externaldiffs"].name
        bucket_gitlfs          = scaleway_object_bucket.buckets["gitlfs"].name
        bucket_packages        = scaleway_object_bucket.buckets["packages"].name
        bucket_registry        = scaleway_object_bucket.buckets["registry"].name
        bucket_terraformstate  = scaleway_object_bucket.buckets["terraformstate"].name
        bucket_tmpbackups      = scaleway_object_bucket.buckets["tmpbackups"].name
        bucket_uploads         = scaleway_object_bucket.buckets["uploads"].name
        # Postgresql
        postgresql_host     = scaleway_rdb_instance.gitlab_postgresql.endpoint_ip
        postgresql_port     = scaleway_rdb_instance.gitlab_postgresql.endpoint_port
        postgresql_database = scaleway_rdb_user.gitlab_user.name
        postgresql_user     = scaleway_rdb_user.gitlab_user.name
        postgresql_password = scaleway_rdb_user.gitlab_user.password
        # SMTP
        smtp_address         = var.smtp_address
        smtp_port            = var.smtp_port
        smtp_username        = var.smtp_username
        smtp_password_secret = kubernetes_secret.smtp_password.metadata[0].name
        smtp_domain          = var.domain
      }
    )
  ]

  provisioner "local-exec" {
    command     = "kubectl delete ingress -n gitlab --all --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = { KUBECONFIG = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig) }
  }
}

# =============================================================================
# Kubernetes - SMTP secret
# =============================================================================

resource "kubernetes_secret" "smtp_password" {
  depends_on = [kubernetes_namespace.namespace]
  metadata {
    name      = "gitlab-smtp-password"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
  data = { password = var.smtp_password }
  type = "opaque"
}

# =============================================================================
# KUBECTL - Gitlab Ingresses
# =============================================================================

resource "null_resource" "gitlab_webservice_ingress" {
  triggers = {
    ingress_file_sha1 = sha1(file("${path.module}/configs/ingressroutes/gitlab-webservice-ingressroute.yml"))
    kubeconfig        = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
    ingress_file_path = terraform.workspace == "production" ? "${path.module}/configs/ingressroutes/gitlab-webservice-ingressroute.yml" : "${path.module}/configs/ingressroutes/dev-gitlab-webservice-ingressroute.yml"
  }
  depends_on = [kubernetes_namespace.namespace, kubernetes_secret.tls_secret]
  provisioner "local-exec" {
    command     = "kubectl apply -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "kubectl delete -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = self.triggers.kubeconfig
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }
}


resource "null_resource" "gitlab_registry_ingress" {
  triggers = {
    ingress_file_sha1 = sha1(file("${path.module}/configs/ingressroutes/gitlab-registry-ingressroute.yml"))
    kubeconfig        = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
    ingress_file_path = terraform.workspace == "production" ? "${path.module}/configs/ingressroutes/gitlab-registry-ingressroute.yml" : "${path.module}/configs/ingressroutes/dev-gitlab-registry-ingressroute.yml"
  }
  depends_on = [kubernetes_namespace.namespace, kubernetes_secret.tls_secret]
  provisioner "local-exec" {
    command     = "kubectl apply -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "kubectl delete -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = self.triggers.kubeconfig
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }
}

resource "null_resource" "gitlab_shell_ingress" {
  triggers = {
    ingress_file_sha1 = sha1(file("${path.module}/configs/ingressroutes/gitlab-shell-ingressroute.yml"))
    kubeconfig        = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
    ingress_file_path = "${path.module}/configs/ingressroutes/gitlab-shell-ingressroute.yml"
  }
  depends_on = [kubernetes_namespace.namespace, kubernetes_secret.tls_secret]
  provisioner "local-exec" {
    command     = "kubectl apply -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = base64encode(data.terraform_remote_state.k8s.outputs.k8s_kubeconfig)
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "kubectl delete -f $FILE_PATH --kubeconfig <(echo $KUBECONFIG | base64 -d)"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      KUBECONFIG = self.triggers.kubeconfig
      FILE_PATH  = self.triggers.ingress_file_path
    }
  }
}

# =============================================================================
# Helm - Install Runner
# =============================================================================

data "kubernetes_secret" "gitlab-gitlab-runner-secret" {
  depends_on = [helm_release.gitlab]
  metadata {
    name      = "gitlab-gitlab-runner-secret"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
}

resource "helm_release" "gitlab-runner" {
  count            = 1
  name             = "gitlab-runner-${count.index}"
  namespace        = "gitlab-runner"
  create_namespace = false
  timeout          = 600

  repository = "https://charts.gitlab.io/"
  chart      = "gitlab-runner"
  version    = "0.24.0"

  set {
    name  = "gitlabUrl"
    value = terraform.workspace == "production" ? "https://gitlab.example.com/" : "https://gitlab.dev.example.com"
  }

  set {
    name  = "rbac.enabled"
    value = "true"
  }

  set {
    name  = "runners.privileged"
    value = "false"
  }

  set_sensitive {
    name  = "runnerRegistrationToken"
    value = data.kubernetes_secret.gitlab-gitlab-runner-secret.data.runner-registration-token
  }
}

resource "helm_release" "gitlab-privileged-runner" {
  count            = 1
  name             = "gitlab-privileged-runner-${count.index}"
  namespace        = "gitlab-runner"
  create_namespace = false
  timeout          = 600

  repository = "https://charts.gitlab.io/"
  chart      = "gitlab-runner"
  version    = "0.24.0"

  set {
    name  = "gitlabUrl"
    value = terraform.workspace == "production" ? "https://gitlab.example.com/" : "https://gitlab.dev.example.com"
  }

  set {
    name  = "rbac.enabled"
    value = "true"
  }

  set {
    name  = "runners.privileged"
    value = "true"
  }

  set_sensitive {
    name  = "runnerRegistrationToken"
    value = data.kubernetes_secret.gitlab-gitlab-runner-secret.data.runner-registration-token
  }
}

# =============================================================================
# Kubernetes - Sidekiq Metrics Service
# =============================================================================

resource "kubernetes_service" "sidekiq_metrics" {
  depends_on = [kubernetes_namespace.namespace]
  metadata {
    name      = "gitlab-sidekiq-metrics"
    namespace = "gitlab"
    labels = {
      app     = "sidekiq"
      release = "gitlab"
    }
  }

  spec {
    selector = {
      app     = "sidekiq"
      release = "gitlab"
    }
    port {
      port        = 3807
      target_port = 3807
    }
    type = "ClusterIP"
  }
}
