output "cluster_role_arn" {
  description = "IAM role ARN for the EKS cluster"
  value       = var.create_base_roles ? aws_iam_role.cluster_role[0].arn : ""
}

output "node_role_arn" {
  description = "IAM role ARN for EKS node groups"
  value       = var.create_base_roles ? aws_iam_role.node_role[0].arn : ""
}

output "node_role_name" {
  description = "Name of the IAM role for EKS node groups"
  value       = var.create_base_roles ? aws_iam_role.node_role[0].name : ""
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider"
  value       = var.create_oidc_provider ? aws_iam_openid_connect_provider.cluster_oidc[0].arn : ""
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider (without https://)"
  value       = var.create_oidc_provider ? replace(aws_iam_openid_connect_provider.cluster_oidc[0].url, "https://", "") : ""
}
