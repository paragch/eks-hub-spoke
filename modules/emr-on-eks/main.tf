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
  }
}

# ── 1. S3 landing zone bucket ─────────────────────────────────────────────────
# Parquet source files land here. Lives in the same account as the EKS cluster.
# Bucket name is deterministic (<cluster>-landing-zone-<account_id>) so it is
# globally unique without needing the random provider.

resource "aws_s3_bucket" "landing_zone" {
  bucket        = local.landing_zone_bucket_name
  force_destroy = false

  tags = merge(var.common_tags, {
    Name    = local.landing_zone_bucket_name
    Purpose = "emr-landing-zone"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "landing_zone" {
  bucket = aws_s3_bucket.landing_zone.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "landing_zone" {
  bucket = aws_s3_bucket.landing_zone.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "landing_zone" {
  bucket = aws_s3_bucket.landing_zone.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── 2. EMR jobs namespace ─────────────────────────────────────────────────────
# The label emr-containers.amazonaws.com/virtualClusterNamespace=true is
# required by the EMR service to discover the namespace.

resource "kubernetes_namespace" "emr_jobs" {
  metadata {
    name = var.emr_namespace

    labels = {
      "emr-containers.amazonaws.com/virtualClusterNamespace" = "true"
      "app.kubernetes.io/managed-by"                         = "terraform"
    }
  }
}

# ── 3. Kubernetes RBAC ────────────────────────────────────────────────────────
# EMR on EKS requires a Role + RoleBinding inside the jobs namespace so the
# EMR service principal (group: emr-containers) can manage pods and read nodes.

resource "kubernetes_role" "emr_containers" {
  metadata {
    name      = "emr-containers"
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "events"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "emr_containers" {
  metadata {
    name      = "emr-containers"
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.emr_containers.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "emr-containers"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [kubernetes_role.emr_containers]
}

# ── 4. Kubernetes ServiceAccount for EMR job runner pods ──────────────────────
# Job pods run under this SA. The Pod Identity association (section 5) binds
# the IAM role to this exact namespace + service account pair.

resource "kubernetes_service_account" "emr_job_runner" {
  metadata {
    name      = var.emr_job_service_account
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [kubernetes_namespace.emr_jobs]
}

# ── 5. Job execution IAM role (Pod Identity) ──────────────────────────────────
# Trusted by the EKS Pod Identity agent (pods.eks.amazonaws.com).
# The Pod Identity association (section 6) restricts which pods can assume it.

resource "aws_iam_role" "emr_job_execution" {
  name = "${var.cluster_name}-emr-job-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSPodIdentity"
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-emr-job-execution"
  })
}

resource "aws_iam_role_policy" "emr_job_execution" {
  name = "${var.cluster_name}-emr-job-execution"
  role = aws_iam_role.emr_job_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "LandingZoneBucketAccess"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ]
          # Covers parquet files, Spark event logs (spark-logs/ prefix), and all outputs
          Resource = "arn:aws:s3:::${aws_s3_bucket.landing_zone.bucket}/*"
        },
        {
          Sid      = "LandingZoneBucketList"
          Effect   = "Allow"
          Action   = "s3:ListBucket"
          Resource = "arn:aws:s3:::${aws_s3_bucket.landing_zone.bucket}"
        },
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:PutLogEvents",
            "logs:CreateLogGroup",
            "logs:CreateLogStream"
          ]
          Resource = "*"
        },
        {
          Sid    = "GlueCatalog"
          Effect = "Allow"
          Action = [
            "glue:GetDatabase",
            "glue:GetTable"
          ]
          Resource = "*"
        }
      ],
      # MSK IAM auth permissions — only added when an MSK cluster ARN is provided.
      # EMR Spark jobs write results to Kafka topics using IAM/TLS (port 9098).
      var.msk_cluster_arn != "" ? [
        {
          Sid    = "MSKIAMAccess"
          Effect = "Allow"
          Action = [
            "kafka-cluster:Connect",
            "kafka-cluster:DescribeCluster",
            "kafka-cluster:DescribeClusterDynamicConfiguration",
            "kafka-cluster:DescribeTopic",
            "kafka-cluster:DescribeTopicDynamicConfiguration",
            "kafka-cluster:CreateTopic",
            "kafka-cluster:AlterTopic",
            "kafka-cluster:WriteData",
            "kafka-cluster:ReadData",
            "kafka-cluster:AlterGroup",
            "kafka-cluster:DescribeGroup",
            "kafka-cluster:DeleteGroup"
          ]
          Resource = [
            var.msk_cluster_arn,
            "${local.msk_topic_arn_prefix}/*",
            "${local.msk_group_arn_prefix}/*"
          ]
        }
      ] : []
    )
  })
}

# ── 6. EKS Pod Identity association ───────────────────────────────────────────
# Binds the job execution IAM role to the emr-job-runner SA in the emr-jobs
# namespace. The eks-pod-identity-agent DaemonSet (already deployed as an EKS
# addon) injects the credentials into matching pods automatically.

resource "aws_eks_pod_identity_association" "emr_job_execution" {
  cluster_name    = var.cluster_name
  namespace       = kubernetes_namespace.emr_jobs.metadata[0].name
  service_account = kubernetes_service_account.emr_job_runner.metadata[0].name
  role_arn        = aws_iam_role.emr_job_execution.arn

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-emr-pod-identity"
  })

  depends_on = [
    kubernetes_service_account.emr_job_runner,
    aws_iam_role.emr_job_execution,
  ]
}

# ── 7. EKS access entry for EMR service-linked role ───────────────────────────
# Grants the EMR service-linked role access to the cluster so it can manage
# pods in the emr-jobs namespace. Uses modern EKS auth (no aws-auth ConfigMap).

resource "aws_eks_access_entry" "emr" {
  cluster_name      = var.cluster_name
  principal_arn     = "arn:aws:iam::${var.account_id}:role/AWSServiceRoleForAmazonEMRContainers"
  type              = "STANDARD"
  kubernetes_groups = ["emr-containers"]

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-emr-access-entry"
  })
}

# ── 8. EMR virtual cluster ────────────────────────────────────────────────────

resource "aws_emr_containers_virtual_cluster" "main" {
  name = local.virtual_cluster_name

  container_provider {
    id   = var.cluster_name
    type = "EKS"

    info {
      eks_info {
        namespace = var.emr_namespace
      }
    }
  }

  tags = merge(var.common_tags, {
    Name = local.virtual_cluster_name
  })

  depends_on = [
    kubernetes_namespace.emr_jobs,
    kubernetes_role_binding.emr_containers,
    aws_eks_access_entry.emr,
    aws_eks_pod_identity_association.emr_job_execution,
  ]
}

# ── 9. MSK ConfigMap ──────────────────────────────────────────────────────────
# Stores the Kafka bootstrap brokers so Spark jobs and notebooks can discover
# the MSK endpoint without hardcoding it in job submission scripts.
# Created only when an MSK cluster is associated with this EMR deployment.

resource "kubernetes_config_map" "kafka_config" {
  count = var.msk_bootstrap_brokers != "" ? 1 : 0

  metadata {
    name      = "kafka-config"
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "kafka"
    }
  }

  data = {
    KAFKA_BOOTSTRAP_SERVERS = var.msk_bootstrap_brokers
    KAFKA_SECURITY_PROTOCOL = "SASL_SSL"
    KAFKA_SASL_MECHANISM    = "AWS_MSK_IAM"
    # Spark Kafka connector settings for job submissions:
    # --conf spark.kafka.bootstrap.servers=<KAFKA_BOOTSTRAP_SERVERS>
    # --conf spark.kafka.security.protocol=SASL_SSL
    # --conf spark.kafka.sasl.mechanism=AWS_MSK_IAM
  }

  depends_on = [kubernetes_namespace.emr_jobs]
}

# ── 10. Spark History Server ──────────────────────────────────────────────────
# Reads Spark event logs from s3://<landing_zone>/spark-logs/ and provides the
# Spark Web UI on port 18080 for inspecting completed and running job DAGs.
#
# To enable event logging in job submissions add:
#   --conf spark.eventLog.enabled=true
#   --conf spark.eventLog.dir=s3://<landing_zone_bucket>/spark-logs/

resource "kubernetes_deployment" "spark_history_server" {
  metadata {
    name      = "spark-history-server"
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name

    labels = {
      "app"                          = "spark-history-server"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "spark-history-server" }
    }

    template {
      metadata {
        labels = { app = "spark-history-server" }
      }

      spec {
        # Runs under emr-job-runner SA — Pod Identity injects AWS credentials
        # so the history server can read Spark event logs from S3.
        service_account_name = kubernetes_service_account.emr_job_runner.metadata[0].name

        container {
          name  = "spark-history-server"
          image = var.spark_image

          command = ["/bin/bash", "-c"]
          args = [
            "/usr/lib/spark/bin/spark-class org.apache.spark.deploy.history.HistoryServer"
          ]

          env {
            name = "SPARK_HISTORY_OPTS"
            value = join(" ", [
              "-Dspark.history.fs.logDirectory=s3://${aws_s3_bucket.landing_zone.bucket}/spark-logs/",
              "-Dspark.history.ui.port=18080",
              "-Dspark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.ContainerCredentialsProvider"
            ])
          }

          port {
            name           = "web-ui"
            container_port = 18080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 18080
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 18080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.emr_job_runner,
    aws_eks_pod_identity_association.emr_job_execution,
  ]
}

resource "kubernetes_service" "spark_history_server" {
  metadata {
    name      = "spark-history-server"
    namespace = kubernetes_namespace.emr_jobs.metadata[0].name

    labels = {
      "app"                          = "spark-history-server"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = { app = "spark-history-server" }

    port {
      name        = "web-ui"
      port        = 18080
      target_port = 18080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.spark_history_server]
}
