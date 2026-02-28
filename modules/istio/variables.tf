variable "cluster_name" {
  description = "EKS cluster name (used for Helm release naming)"
  type        = string
}

variable "istio_version" {
  description = "Istio Helm chart version"
  type        = string
  default     = "1.24.3"
}

variable "enable_ingress_gateway" {
  description = "Whether to deploy the Istio ingress gateway"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
