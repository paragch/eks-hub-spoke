data "aws_availability_zones" "available" {
  state = "available"
}

# ── Remote state from prod ─────────────────────────────────────────────────────
# Provides prod VPC/subnet/route table IDs and the Amazon MQ failover URL.
# The kubernetes provider uses var.prod_cluster_endpoint/ca_data (variables)
# because provider configs are evaluated before data sources.

data "terraform_remote_state" "prod" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/terraform.tfstate"
    region = var.aws_region
  }
}

# ── prod-data VPC ─────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = "prod-data"
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets     = var.public_subnet_cidrs
  private_subnets    = var.private_subnet_cidrs
  common_tags        = var.common_tags
}

# ── VPC Peering ────────────────────────────────────────────────────────────────
# prod-data (requester) ↔ prod (accepter).
# All resources that touch both accounts live here so a single
# `terraform destroy` tears down the entire peering cleanly.

resource "aws_vpc_peering_connection" "to_prod" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.terraform_remote_state.prod.outputs.vpc_id
  peer_region = var.aws_region

  tags = merge(var.common_tags, {
    Name = "prod-data-to-prod"
    Side = "requester"
  })
}

resource "aws_vpc_peering_connection_accepter" "prod" {
  provider = aws.prod

  vpc_peering_connection_id = aws_vpc_peering_connection.to_prod.id
  auto_accept               = true

  tags = merge(var.common_tags, {
    Name = "prod-to-prod-data"
    Side = "accepter"
  })
}

# Routes on prod-data side → prod CIDR
resource "aws_route" "prod_data_to_prod" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = data.terraform_remote_state.prod.outputs.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_prod.id

  depends_on = [aws_vpc_peering_connection_accepter.prod]
}

# Routes on prod side → prod-data CIDR (managed from this workspace via aws.prod)
resource "aws_route" "prod_to_prod_data" {
  provider = aws.prod
  count    = length(data.terraform_remote_state.prod.outputs.private_route_table_ids)

  route_table_id            = data.terraform_remote_state.prod.outputs.private_route_table_ids[count.index]
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_prod.id

  depends_on = [aws_vpc_peering_connection_accepter.prod]
}

# ── db-writer IAM role (in prod account) ──────────────────────────────────────
# Created in the prod account via aws.prod so the role can be bound to the
# eks-prod EKS cluster via Pod Identity.

resource "aws_iam_role" "db_writer" {
  provider = aws.prod

  name        = "db-writer"
  description = "IAM role for the db-writer microservice (Pod Identity on eks-prod)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "db-writer"
  })
}

resource "aws_iam_role_policy" "db_writer" {
  provider = aws.prod

  name = "db-writer-policy"
  role = aws_iam_role.db_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OpenSearchAccess"
        Effect = "Allow"
        Action = ["es:ESHttp*"]
        Resource = [
          "${module.opensearch.domain_arn}/*"
        ]
      },
      {
        Sid    = "NeptuneAccess"
        Effect = "Allow"
        Action = ["neptune-db:*"]
        Resource = [
          "arn:aws:neptune-db:${var.aws_region}:${var.account_id}:cluster:${module.neptune.cluster_resource_id}/*"
        ]
      }
    ]
  })

  depends_on = [module.opensearch, module.neptune]
}

resource "aws_eks_pod_identity_association" "db_writer" {
  provider = aws.prod

  cluster_name    = var.prod_cluster_name
  namespace       = "db-writer"
  service_account = "db-writer"
  role_arn        = aws_iam_role.db_writer.arn

  tags = merge(var.common_tags, {
    Name = "db-writer-pod-identity"
  })
}

# ── OpenSearch (prod-data account) ────────────────────────────────────────────

module "opensearch" {
  source = "../../modules/opensearch"

  cluster_name        = "prod-data"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  allowed_cidr_blocks = [data.terraform_remote_state.prod.outputs.vpc_cidr]
  opensearch_version  = var.opensearch_version
  instance_type       = var.opensearch_instance_type
  instance_count      = var.opensearch_instance_count
  db_writer_role_arn  = aws_iam_role.db_writer.arn
  common_tags         = var.common_tags

  depends_on = [module.vpc]
}

# ── Aurora PostgreSQL (prod-data account) ─────────────────────────────────────

module "aurora" {
  source = "../../modules/aurora"

  cluster_name        = "prod-data"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  allowed_cidr_blocks = [data.terraform_remote_state.prod.outputs.vpc_cidr]
  engine_version      = var.aurora_engine_version
  instance_class      = var.aurora_instance_class
  db_name             = var.aurora_db_name
  db_username         = var.aurora_db_username
  db_password         = var.aurora_db_password
  common_tags         = var.common_tags

  depends_on = [module.vpc]
}

# ── Neptune (prod-data account) ───────────────────────────────────────────────

module "neptune" {
  source = "../../modules/neptune"

  cluster_name        = "prod-data"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  allowed_cidr_blocks = [data.terraform_remote_state.prod.outputs.vpc_cidr]
  engine_version      = var.neptune_engine_version
  instance_class      = var.neptune_instance_class
  common_tags         = var.common_tags

  depends_on = [module.vpc]
}

# ── Kubernetes namespace ───────────────────────────────────────────────────────

resource "kubernetes_namespace" "db_writer" {
  metadata {
    name = "db-writer"
    labels = {
      managed-by = "terraform"
    }
  }
}

# ── Kubernetes service account ─────────────────────────────────────────────────

resource "kubernetes_service_account" "db_writer" {
  metadata {
    name      = "db-writer"
    namespace = kubernetes_namespace.db_writer.metadata[0].name
    annotations = {
      "eks.amazonaws.com/pod-identity-webhook" = "true"
    }
  }

  depends_on = [kubernetes_namespace.db_writer]
}

# ── ConfigMap — database endpoints ────────────────────────────────────────────

resource "kubernetes_config_map" "db_endpoints" {
  metadata {
    name      = "db-endpoints"
    namespace = kubernetes_namespace.db_writer.metadata[0].name
  }

  data = {
    OPENSEARCH_ENDPOINT = "https://${module.opensearch.endpoint}"
    NEPTUNE_ENDPOINT    = "wss://${module.neptune.endpoint}:${module.neptune.port}/gremlin"
    AURORA_ENDPOINT     = module.aurora.cluster_endpoint
    AURORA_PORT         = "5432"
    AURORA_DB_NAME      = var.aurora_db_name
    AURORA_USERNAME     = var.aurora_db_username
    # Amazon MQ failover URL read from prod remote state
    MQ_FAILOVER_URL     = data.terraform_remote_state.prod.outputs.mq_amqp_failover_url
    MQ_USERNAME         = var.mq_username
    AWS_REGION          = var.aws_region
  }

  depends_on = [kubernetes_namespace.db_writer, module.opensearch, module.aurora, module.neptune]
}

# ── Secret — Aurora password ───────────────────────────────────────────────────

resource "kubernetes_secret" "aurora_credentials" {
  metadata {
    name      = "aurora-credentials"
    namespace = kubernetes_namespace.db_writer.metadata[0].name
  }

  data = {
    password = var.aurora_db_password
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.db_writer]
}

# ── Secret — Amazon MQ password ───────────────────────────────────────────────

resource "kubernetes_secret" "mq_credentials" {
  metadata {
    name      = "mq-credentials"
    namespace = kubernetes_namespace.db_writer.metadata[0].name
  }

  data = {
    password = var.mq_password
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.db_writer]
}

# ── db-writer Deployment ───────────────────────────────────────────────────────
# Reads from Amazon MQ (ActiveMQ) in prod and writes to all three databases
# in prod-data over the VPC peering connection.

resource "kubernetes_deployment" "db_writer" {
  metadata {
    name      = "db-writer"
    namespace = kubernetes_namespace.db_writer.metadata[0].name
    labels = {
      app = "db-writer"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "db-writer"
      }
    }

    template {
      metadata {
        labels = {
          app = "db-writer"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.db_writer.metadata[0].name

        container {
          name  = "db-writer"
          image = var.db_writer_image

          env_from {
            config_map_ref {
              name = kubernetes_config_map.db_endpoints.metadata[0].name
            }
          }

          env {
            name = "AURORA_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.aurora_credentials.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name = "MQ_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mq_credentials.metadata[0].name
                key  = "password"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.db_writer,
    kubernetes_config_map.db_endpoints,
    kubernetes_secret.aurora_credentials,
    kubernetes_secret.mq_credentials,
    aws_eks_pod_identity_association.db_writer,
  ]
}
