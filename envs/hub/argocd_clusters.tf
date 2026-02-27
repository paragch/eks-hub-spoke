# Register dev and prod spoke clusters in Hub ArgoCD
# ArgoCD cluster secret format:
#   - label argocd.argoproj.io/secret-type=cluster
#   - data: name, server, config (JSON with bearerToken + tlsClientConfig)

locals {
  dev_cluster_endpoint = data.terraform_remote_state.dev.outputs.cluster_endpoint
  dev_cluster_ca_data  = data.terraform_remote_state.dev.outputs.cluster_certificate_authority_data
  dev_argocd_token     = data.terraform_remote_state.dev.outputs.argocd_manager_token

  prod_cluster_endpoint = data.terraform_remote_state.prod.outputs.cluster_endpoint
  prod_cluster_ca_data  = data.terraform_remote_state.prod.outputs.cluster_certificate_authority_data
  prod_argocd_token     = data.terraform_remote_state.prod.outputs.argocd_manager_token
}

resource "kubernetes_secret" "argocd_cluster_dev" {
  metadata {
    name      = "cluster-eks-dev"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "cluster-role"                    = "spoke"
      "environment"                     = "dev"
    }
  }

  data = {
    name   = "eks-dev"
    server = local.dev_cluster_endpoint
    config = jsonencode({
      bearerToken = local.dev_argocd_token
      tlsClientConfig = {
        insecure = false
        caData   = local.dev_cluster_ca_data
      }
    })
  }

  type = "Opaque"

  depends_on = [time_sleep.wait_for_argocd]
}

resource "kubernetes_secret" "argocd_cluster_prod" {
  metadata {
    name      = "cluster-eks-prod"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "cluster-role"                    = "spoke"
      "environment"                     = "prod"
    }
  }

  data = {
    name   = "eks-prod"
    server = local.prod_cluster_endpoint
    config = jsonencode({
      bearerToken = local.prod_argocd_token
      tlsClientConfig = {
        insecure = false
        caData   = local.prod_cluster_ca_data
      }
    })
  }

  type = "Opaque"

  depends_on = [time_sleep.wait_for_argocd]
}
