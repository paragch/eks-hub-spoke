variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-data"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "Worker node instance type"
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.8.26"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.3.3"
}

variable "istio_version" {
  description = "Istio Helm chart version"
  type        = string
  default     = "1.24.3"
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.11.0"
}

variable "kafka_version" {
  description = "Apache Kafka version for the MSK cluster"
  type        = string
  default     = "3.6.0"
}

variable "kafka_broker_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.m5.large"
}

variable "jupyterhub_chart_version" {
  description = "JupyterHub Helm chart version"
  type        = string
  default     = "4.1.0"
}

variable "mq_username" {
  description = "Amazon MQ admin username"
  type        = string
  default     = "admin"
}

variable "mq_password" {
  description = "Amazon MQ admin password (12–250 characters)"
  type        = string
  sensitive   = true
}

variable "mq_instance_type" {
  description = "Amazon MQ broker instance type"
  type        = string
  default     = "mq.m5.large"
}

variable "mq_deployment_mode" {
  description = "Amazon MQ deployment mode (ACTIVE_STANDBY_MULTI_AZ or SINGLE_INSTANCE)"
  type        = string
  default     = "ACTIVE_STANDBY_MULTI_AZ"
}

variable "account_id" {
  description = "AWS account ID for the data member account"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
