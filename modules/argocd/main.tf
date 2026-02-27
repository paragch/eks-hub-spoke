# ArgoCD Module — deploys argo-cd Helm chart in hub or spoke mode

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [
    file("${path.module}/values-${var.mode}.yaml")
  ]

  set {
    name  = "global.domain"
    value = var.argocd_domain
  }

  timeout = 600

  wait          = true
  wait_for_jobs = true
}
