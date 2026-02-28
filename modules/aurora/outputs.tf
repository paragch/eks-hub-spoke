output "cluster_arn" {
  description = "ARN of the Aurora cluster"
  value       = aws_rds_cluster.aurora.arn
}

output "cluster_endpoint" {
  description = "Writer endpoint for the Aurora cluster"
  value       = aws_rds_cluster.aurora.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint for the Aurora cluster"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_identifier" {
  description = "Cluster identifier"
  value       = aws_rds_cluster.aurora.cluster_identifier
}

output "security_group_id" {
  description = "Security group ID attached to the Aurora cluster"
  value       = aws_security_group.aurora.id
}
