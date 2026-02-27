variable "mode" {
  description = "ArgoCD deployment mode: hub or spoke"
  type        = string

  validation {
    condition     = contains(["hub", "spoke"], var.mode)
    error_message = "mode must be 'hub' or 'spoke'"
  }
}

variable "chart_version" {
  description = "argo-cd Helm chart version"
  type        = string
  default     = "7.8.26"
}

variable "namespace" {
  description = "Kubernetes namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_domain" {
  description = "Domain for ArgoCD (used in Ingress/LB)"
  type        = string
  default     = "argocd.example.com"
}
