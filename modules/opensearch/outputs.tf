output "domain_arn" {
  description = "ARN of the OpenSearch domain"
  value       = aws_opensearch_domain.main.arn
}

output "domain_name" {
  description = "Name of the OpenSearch domain"
  value       = aws_opensearch_domain.main.domain_name
}

output "endpoint" {
  description = "OpenSearch VPC endpoint (HTTPS, no scheme prefix)"
  value       = aws_opensearch_domain.main.endpoint
}

output "security_group_id" {
  description = "Security group ID attached to the OpenSearch domain"
  value       = aws_security_group.opensearch.id
}
