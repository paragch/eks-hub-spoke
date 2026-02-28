output "cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.main.arn
}

output "cluster_name" {
  description = "MSK cluster name"
  value       = aws_msk_cluster.main.cluster_name
}

output "bootstrap_brokers_iam" {
  description = "Bootstrap broker string for IAM/TLS auth (port 9098) — use as kafka.bootstrap.servers in Spark jobs"
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}

output "security_group_id" {
  description = "Security group ID attached to MSK brokers"
  value       = aws_security_group.msk.id
}

output "zookeeper_connect_string" {
  description = "ZooKeeper connection string (for admin tooling)"
  value       = aws_msk_cluster.main.zookeeper_connect_string
}
