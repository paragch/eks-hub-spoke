terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}

# ── Istio system namespace ─────────────────────────────────────────────────────

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ── Istio base CRDs and cluster-wide resources ────────────────────────────────

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  set {
    name  = "global.istioNamespace"
    value = kubernetes_namespace.istio_system.metadata[0].name
  }

  depends_on = [kubernetes_namespace.istio_system]
}

# ── Istiod control plane ───────────────────────────────────────────────────────

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  set {
    name  = "global.istioNamespace"
    value = kubernetes_namespace.istio_system.metadata[0].name
  }

  depends_on = [helm_release.istio_base]
}

# ── Istio ingress gateway ──────────────────────────────────────────────────────

resource "helm_release" "istio_ingress" {
  count = var.enable_ingress_gateway ? 1 : 0

  name       = "istio-ingress"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  # Annotate the gateway Service so the AWS Load Balancer Controller provisions
  # an internet-facing NLB in IP target mode (pods receive traffic directly —
  # no kube-proxy hop). This is the recommended AWS pattern for Istio: L4 NLB
  # in front of Istio's own L7 routing, avoiding double TLS termination.
  values = [
    yamlencode({
      service = {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"             = "external"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"           = "internet-facing"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"  = "ip"
        }
      }
    })
  ]

  depends_on = [helm_release.istiod]
}
