output "opensearch_endpoint" {
  description = "OpenSearch VPC endpoint (HTTPS)"
  value       = module.opensearch.endpoint
}

output "opensearch_domain_arn" {
  description = "ARN of the OpenSearch domain"
  value       = module.opensearch.domain_arn
}

output "aurora_cluster_endpoint" {
  description = "Aurora PostgreSQL writer endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora PostgreSQL reader endpoint"
  value       = module.aurora.reader_endpoint
}

output "aurora_cluster_arn" {
  description = "ARN of the Aurora cluster"
  value       = module.aurora.cluster_arn
}

output "neptune_endpoint" {
  description = "Neptune writer endpoint"
  value       = module.neptune.endpoint
}

output "neptune_cluster_arn" {
  description = "ARN of the Neptune cluster"
  value       = module.neptune.cluster_arn
}

output "neptune_cluster_resource_id" {
  description = "Neptune cluster resource ID (used in IAM policy ARN)"
  value       = module.neptune.cluster_resource_id
}

output "vpc_peering_connection_id" {
  description = "VPC peering connection ID (prod-data ↔ prod)"
  value       = aws_vpc_peering_connection.to_prod.id
}
