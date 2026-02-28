data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets     = var.public_subnet_cidrs
  private_subnets    = var.private_subnet_cidrs
  common_tags        = var.common_tags
}

# ── IAM Phase 1 ───────────────────────────────────────────────────────────────

module "iam" {
  source = "../../modules/iam"

  cluster_name      = var.cluster_name
  create_base_roles = true
  common_tags       = var.common_tags
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/eks-cluster"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  cluster_role_arn   = module.iam.cluster_role_arn
  node_role_arn      = module.iam.node_role_arn
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  common_tags        = var.common_tags

  depends_on = [module.iam]
}

# ── IAM Phase 2 ───────────────────────────────────────────────────────────────

module "iam_oidc" {
  source = "../../modules/iam"

  cluster_name            = var.cluster_name
  create_base_roles       = false
  create_oidc_provider    = true
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  common_tags             = var.common_tags

  depends_on = [module.eks]
}

# ── ArgoCD Spoke ──────────────────────────────────────────────────────────────

module "argocd" {
  source = "../../modules/argocd"

  mode          = "spoke"
  chart_version = var.argocd_chart_version
  namespace     = "argocd"

  depends_on = [module.eks]
}

# ── Karpenter ─────────────────────────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name      = var.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.iam_oidc.oidc_provider_arn
  oidc_provider_url = module.iam_oidc.oidc_provider_url
  node_role_arn     = module.iam.node_role_arn
  node_role_name    = module.iam.node_role_name
  karpenter_version = var.karpenter_version
  common_tags       = var.common_tags

  depends_on = [module.iam_oidc]
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────

module "aws_load_balancer_controller" {
  source = "../../modules/aws-load-balancer-controller"

  cluster_name  = var.cluster_name
  vpc_id        = module.vpc.vpc_id
  account_id    = var.account_id
  region        = var.aws_region
  chart_version = var.lbc_chart_version
  common_tags   = var.common_tags

  depends_on = [module.eks]
}

# ── MSK (Managed Kafka) ───────────────────────────────────────────────────────
# EMR Spark jobs write their results to Kafka topics here.
# IAM authentication (port 9098) — no passwords or certificates needed.

module "msk" {
  source = "../../modules/msk"

  cluster_name       = var.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr           = module.vpc.vpc_cidr_block
  kafka_version      = var.kafka_version
  broker_instance_type = var.kafka_broker_instance_type
  common_tags        = var.common_tags

  depends_on = [module.vpc]
}

# ── EMR on EKS ────────────────────────────────────────────────────────────────

module "emr_on_eks" {
  source = "../../modules/emr-on-eks"

  cluster_name          = var.cluster_name
  account_id            = var.account_id
  virtual_cluster_name  = var.virtual_cluster_name
  msk_cluster_arn       = module.msk.cluster_arn
  msk_bootstrap_brokers = module.msk.bootstrap_brokers_iam
  common_tags           = var.common_tags

  depends_on = [module.eks, module.msk]
}

# ── Amazon MQ ─────────────────────────────────────────────────────────────────
# ActiveMQ ACTIVE_STANDBY_MULTI_AZ broker in the same VPC as MSK.
# A Kafka consumer bridge (running in EKS) reads from MSK topics and publishes
# to Amazon MQ queues/topics via AMQP (port 5671). Clients in all four accounts
# (hub, dev, prod, data) reach this broker over the Transit Gateway.

module "amazon_mq" {
  source = "../../modules/amazon-mq"

  cluster_name       = var.cluster_name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_type      = var.mq_instance_type
  deployment_mode    = var.mq_deployment_mode
  mq_username        = var.mq_username
  mq_password        = var.mq_password
  common_tags        = var.common_tags

  depends_on = [module.vpc]
}

# ── JupyterHub ────────────────────────────────────────────────────────────────
# PySpark notebook environment for data scientists. Single-user pods inherit
# the EMR job execution role via Pod Identity (S3 + MSK + EMR API access).

module "jupyterhub" {
  source = "../../modules/jupyterhub"

  cluster_name               = var.cluster_name
  emr_job_execution_role_arn = module.emr_on_eks.job_execution_role_arn
  kafka_bootstrap_brokers    = module.msk.bootstrap_brokers_iam
  emr_virtual_cluster_id     = module.emr_on_eks.virtual_cluster_id
  spark_log_bucket           = module.emr_on_eks.landing_zone_bucket_name
  chart_version              = var.jupyterhub_chart_version
  common_tags                = var.common_tags

  depends_on = [module.emr_on_eks, module.aws_load_balancer_controller]
}
