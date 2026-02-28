output "istio_namespace" {
  description = "Kubernetes namespace where Istio is installed"
  value       = kubernetes_namespace.istio_system.metadata[0].name
}

output "istio_version" {
  description = "Istio version deployed"
  value       = var.istio_version
}
