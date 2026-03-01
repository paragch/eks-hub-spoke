output "cluster_name" {
  description = "Hub EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Hub EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "Hub VPC ID"
  value       = module.vpc.vpc_id
}

output "argocd_prod_cluster_secret" {
  description = "Name of the ArgoCD secret for prod cluster"
  value       = kubernetes_secret.argocd_cluster_prod.metadata[0].name
}
