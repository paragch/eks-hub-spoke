variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the OIDC provider (without https://)"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the IAM role for EKS node groups"
  type        = string
}

variable "node_role_name" {
  description = "Name of the IAM role for EKS node groups"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.3.3"
}

variable "karpenter_namespace" {
  description = "Kubernetes namespace for Karpenter"
  type        = string
  default     = "karpenter"
}

variable "nodepool_instance_families" {
  description = "EC2 instance families for the default NodePool"
  type        = list(string)
  default     = ["m5", "m6i", "c5", "c6i", "r5", "r6i"]
}

variable "nodepool_instance_sizes" {
  description = "EC2 instance sizes for the default NodePool"
  type        = list(string)
  default     = ["large", "xlarge", "2xlarge"]
}

variable "nodepool_capacity_types" {
  description = "Capacity types for the default NodePool (spot, on-demand)"
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "nodepool_cpu_limit" {
  description = "CPU limit for the default NodePool"
  type        = string
  default     = "1000"
}

variable "nodepool_memory_limit" {
  description = "Memory limit for the default NodePool"
  type        = string
  default     = "1000Gi"
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
