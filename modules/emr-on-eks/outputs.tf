output "virtual_cluster_id" {
  description = "ID of the EMR virtual cluster"
  value       = aws_emr_containers_virtual_cluster.main.id
}

output "virtual_cluster_arn" {
  description = "ARN of the EMR virtual cluster"
  value       = aws_emr_containers_virtual_cluster.main.arn
}

output "job_execution_role_arn" {
  description = "ARN of the IAM role used by EMR job executions (Pod Identity)"
  value       = aws_iam_role.emr_job_execution.arn
}

output "emr_namespace" {
  description = "Kubernetes namespace where EMR jobs run"
  value       = kubernetes_namespace.emr_jobs.metadata[0].name
}

output "emr_job_service_account" {
  description = "Kubernetes ServiceAccount name used by EMR job runner pods"
  value       = kubernetes_service_account.emr_job_runner.metadata[0].name
}

output "landing_zone_bucket_name" {
  description = "S3 bucket name for the EMR parquet landing zone"
  value       = aws_s3_bucket.landing_zone.bucket
}

output "landing_zone_bucket_arn" {
  description = "S3 bucket ARN for the EMR parquet landing zone"
  value       = aws_s3_bucket.landing_zone.arn
}

output "spark_history_server_service" {
  description = "Kubernetes Service name for the Spark History Server (ClusterIP:18080 — use kubectl port-forward to access)"
  value       = kubernetes_service.spark_history_server.metadata[0].name
}

output "kafka_config_map_name" {
  description = "ConfigMap name in the emr-jobs namespace containing Kafka endpoint configuration (empty string if no MSK cluster configured)"
  value       = length(kubernetes_config_map.kafka_config) > 0 ? kubernetes_config_map.kafka_config[0].metadata[0].name : ""
}
