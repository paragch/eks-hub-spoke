output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Cluster CA data (base64)"
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = module.vpc.vpc_cidr_block
}

output "private_route_table_ids" {
  description = "Private route table IDs"
  value       = module.vpc.private_route_table_ids
}

output "cluster_security_group_id" {
  description = "Cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (needed by hub transit-gateway module)"
  value       = module.vpc.private_subnet_ids
}

output "argocd_manager_token" {
  description = "argocd-manager SA token (sensitive)"
  value       = kubernetes_secret.argocd_manager_token.data["token"]
  sensitive   = true
}

output "emr_virtual_cluster_id" {
  description = "EMR virtual cluster ID"
  value       = module.emr_on_eks.virtual_cluster_id
}

output "emr_job_execution_role_arn" {
  description = "ARN of the EMR job execution IAM role"
  value       = module.emr_on_eks.job_execution_role_arn
}

output "emr_landing_zone_bucket_name" {
  description = "S3 bucket name for the EMR parquet landing zone"
  value       = module.emr_on_eks.landing_zone_bucket_name
}

output "emr_landing_zone_bucket_arn" {
  description = "S3 bucket ARN for the EMR parquet landing zone"
  value       = module.emr_on_eks.landing_zone_bucket_arn
}

output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = module.msk.cluster_arn
}

output "msk_bootstrap_brokers_iam" {
  description = "MSK bootstrap broker string for IAM/TLS auth (port 9098)"
  value       = module.msk.bootstrap_brokers_iam
}

output "jupyterhub_namespace" {
  description = "Kubernetes namespace where JupyterHub is deployed"
  value       = module.jupyterhub.namespace
}

output "mq_broker_id" {
  description = "Amazon MQ broker ID"
  value       = module.amazon_mq.broker_id
}

output "mq_amqp_failover_url" {
  description = "Amazon MQ AMQP+SSL failover URL for client configuration (port 5671)"
  value       = module.amazon_mq.amqp_failover_url
}

output "mq_console_url" {
  description = "Amazon MQ ActiveMQ web console URL (accessible from within the VPC only)"
  value       = module.amazon_mq.console_url
}
