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

# ── IAM Phase 1 — cluster + node roles ───────────────────────────────────────

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

# ── IAM Phase 2 — OIDC provider ──────────────────────────────────────────────

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

# ── Istio ─────────────────────────────────────────────────────────────────────

module "istio" {
  source = "../../modules/istio"

  cluster_name  = var.cluster_name
  istio_version = var.istio_version

  depends_on = [module.eks, module.aws_load_balancer_controller]
}
