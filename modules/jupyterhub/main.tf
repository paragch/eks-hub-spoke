terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
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

# ── 1. Namespace ──────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "jupyterhub" {
  metadata {
    name = "jupyterhub"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ── 2. ServiceAccount for single-user notebook pods ───────────────────────────
# Pod Identity association (section 3) maps this SA to the EMR job execution
# role, giving notebook pods the same S3 and MSK permissions as EMR Spark jobs.

resource "kubernetes_service_account" "jupyter_runner" {
  metadata {
    name      = "jupyter-runner"
    namespace = kubernetes_namespace.jupyterhub.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [kubernetes_namespace.jupyterhub]
}

# ── 3. Pod Identity association ───────────────────────────────────────────────
# Binds the EMR job execution role to the jupyter-runner SA so that notebook
# pods can read/write S3 parquet data and produce to MSK topics.

resource "aws_eks_pod_identity_association" "jupyter_runner" {
  cluster_name    = var.cluster_name
  namespace       = kubernetes_namespace.jupyterhub.metadata[0].name
  service_account = kubernetes_service_account.jupyter_runner.metadata[0].name
  role_arn        = var.emr_job_execution_role_arn

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-jupyter-pod-identity"
  })

  depends_on = [kubernetes_service_account.jupyter_runner]
}

# ── 4. JupyterHub Helm release ────────────────────────────────────────────────
# Single-user servers run the official PySpark notebook image and receive:
#   - AWS credentials via Pod Identity (S3, MSK, EMR API)
#   - Kafka endpoint and EMR cluster ID as environment variables
#   - Persistent storage via EBS CSI (requires aws-ebs-csi-driver addon)
# The Hub proxy is exposed via an internet-facing NLB (AWS Load Balancer
# Controller must be deployed on the cluster before applying this module).

locals {
  # Build extra env map — only include keys that have non-empty values
  singleuser_extra_env = merge(
    {
      KAFKA_SECURITY_PROTOCOL = "SASL_SSL"
      KAFKA_SASL_MECHANISM    = "AWS_MSK_IAM"
    },
    var.kafka_bootstrap_brokers != "" ? { KAFKA_BOOTSTRAP_SERVERS = var.kafka_bootstrap_brokers } : {},
    var.emr_virtual_cluster_id != "" ? { EMR_VIRTUAL_CLUSTER_ID = var.emr_virtual_cluster_id } : {},
    var.spark_log_bucket != "" ? { SPARK_LOG_DIR = "s3://${var.spark_log_bucket}/spark-logs/" } : {}
  )
}

resource "helm_release" "jupyterhub" {
  name       = "jupyterhub"
  repository = "https://hub.jupyter.org/helm-chart/"
  chart      = "jupyterhub"
  version    = var.chart_version
  namespace  = kubernetes_namespace.jupyterhub.metadata[0].name

  values = [
    yamlencode({
      hub = {
        config = {
          # DummyAuthenticator allows any username/password for quick onboarding.
          # Replace with OAuth2 or LDAP authenticator for production use.
          JupyterHub = {
            authenticator_class = "dummy"
          }
          DummyAuthenticator = {
            password = ""
          }
          Authenticator = {
            allow_all = true
          }
        }
      }

      singleuser = {
        image = {
          name = var.singleuser_image
          tag  = var.singleuser_image_tag
        }

        defaultUrl = "/lab"

        # Reuse the jupyter-runner SA so Pod Identity injects AWS credentials
        serviceAccountName = kubernetes_service_account.jupyter_runner.metadata[0].name

        extraEnv = local.singleuser_extra_env

        # Persistent notebook storage backed by EBS (aws-ebs-csi-driver addon)
        storage = {
          type = "dynamic"
          dynamic = {
            storageClassName = var.storage_class
            pvcNamePrefix    = "claim"
            capacity         = var.storage_capacity
          }
        }

        # Resource defaults for notebook pods
        resources = {
          requests = {
            cpu    = "500m"
            memory = "1Gi"
          }
          limits = {
            cpu    = "2"
            memory = "4Gi"
          }
        }
      }

      proxy = {
        service = {
          # Internet-facing NLB managed by the AWS Load Balancer Controller
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          }
        }
      }
    })
  ]

  timeout       = 600
  wait          = true
  wait_for_jobs = true

  depends_on = [
    aws_eks_pod_identity_association.jupyter_runner,
    kubernetes_namespace.jupyterhub,
  ]
}
