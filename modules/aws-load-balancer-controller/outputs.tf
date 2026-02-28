output "iam_role_arn" {
  description = "ARN of the IAM role used by the AWS Load Balancer Controller"
  value       = aws_iam_role.lbc.arn
}

output "iam_role_name" {
  description = "Name of the IAM role used by the AWS Load Balancer Controller"
  value       = aws_iam_role.lbc.name
}

output "helm_release_status" {
  description = "Helm release status"
  value       = helm_release.aws_load_balancer_controller.status
}
