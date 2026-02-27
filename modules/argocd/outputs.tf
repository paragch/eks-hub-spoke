output "namespace" {
  description = "Namespace where ArgoCD is deployed"
  value       = helm_release.argocd.namespace
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.argocd.name
}
