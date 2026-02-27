variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "create_base_roles" {
  description = "Whether to create cluster and node IAM roles (Phase 1)"
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Whether to create the OIDC provider (Phase 2, requires cluster to exist)"
  type        = bool
  default     = false
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL from the EKS cluster (required for Phase 2)"
  type        = string
  default     = ""
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
