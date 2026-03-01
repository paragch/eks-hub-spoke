# Apply AppProjects and ApplicationSets to Hub ArgoCD via kubectl provider

resource "kubectl_manifest" "infra_project" {
  yaml_body = file("${path.module}/../../gitops/hub/projects/infra-project.yaml")

  depends_on = [
    kubernetes_secret.argocd_cluster_prod
  ]
}

resource "kubectl_manifest" "apps_project" {
  yaml_body = file("${path.module}/../../gitops/hub/projects/apps-project.yaml")

  depends_on = [
    kubernetes_secret.argocd_cluster_prod
  ]
}

resource "kubectl_manifest" "infra_apps_appset" {
  yaml_body = file("${path.module}/../../gitops/hub/appsets/infra-apps-appset.yaml")

  depends_on = [
    kubectl_manifest.infra_project
  ]
}

resource "kubectl_manifest" "spoke_apps_appset" {
  yaml_body = file("${path.module}/../../gitops/hub/appsets/spoke-apps-appset.yaml")

  depends_on = [
    kubectl_manifest.apps_project
  ]
}
