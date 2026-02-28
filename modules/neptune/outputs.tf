output "cluster_arn" {
  description = "ARN of the Neptune cluster"
  value       = aws_neptune_cluster.neptune.arn
}

output "cluster_resource_id" {
  description = "Neptune cluster resource ID (used in IAM policy ARN: arn:aws:neptune-db:::cluster:<id>/*)"
  value       = aws_neptune_cluster.neptune.cluster_resource_id
}

output "endpoint" {
  description = "Writer endpoint for the Neptune cluster"
  value       = aws_neptune_cluster.neptune.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint for the Neptune cluster"
  value       = aws_neptune_cluster.neptune.reader_endpoint
}

output "port" {
  description = "Neptune port (8182)"
  value       = aws_neptune_cluster.neptune.port
}

output "security_group_id" {
  description = "Security group ID attached to the Neptune cluster"
  value       = aws_security_group.neptune.id
}
