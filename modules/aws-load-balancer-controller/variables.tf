variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed to the LBC Helm chart so it can discover subnets"
  type        = string
}

variable "account_id" {
  description = "AWS account ID where the cluster lives"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "chart_version" {
  description = "aws-load-balancer-controller Helm chart version"
  type        = string
  default     = "1.11.0"
}

variable "namespace" {
  description = "Namespace to install the controller into"
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Kubernetes service account name for the controller"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "common_tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}
