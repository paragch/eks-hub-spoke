output "namespace" {
  description = "Kubernetes namespace where JupyterHub is deployed"
  value       = kubernetes_namespace.jupyterhub.metadata[0].name
}

output "service_account_name" {
  description = "ServiceAccount name used by single-user notebook pods"
  value       = kubernetes_service_account.jupyter_runner.metadata[0].name
}

output "helm_release_status" {
  description = "Helm release status"
  value       = helm_release.jupyterhub.status
}
