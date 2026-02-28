output "karpenter_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_role_name" {
  description = "Name of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller.name
}

output "karpenter_namespace" {
  description = "Kubernetes namespace where Karpenter is deployed"
  value       = var.karpenter_namespace
}
