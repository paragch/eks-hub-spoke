data "aws_availability_zones" "available" {
  state = "available"
}

# ── Remote state from accounts workspace ──────────────────────────────────────
# Provides account IDs as a cross-reference. Note: providers.tf uses variables
# for account IDs because provider configs cannot reference data sources.

data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "accounts/terraform.tfstate"
    region = var.aws_region
  }
}

# ── Remote state from prod spoke ──────────────────────────────────────────────

data "terraform_remote_state" "prod" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/terraform.tfstate"
    region = var.aws_region
  }
}

# ── Hub VPC ───────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets     = var.public_subnet_cidrs
  private_subnets    = var.private_subnet_cidrs
  common_tags        = var.common_tags
}

# ── Hub IAM Phase 1 ───────────────────────────────────────────────────────────

module "iam" {
  source = "../../modules/iam"

  cluster_name      = var.cluster_name
  create_base_roles = true
  common_tags       = var.common_tags
}

# ── Hub EKS Cluster ───────────────────────────────────────────────────────────

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

# ── Hub IAM Phase 2 ───────────────────────────────────────────────────────────

module "iam_oidc" {
  source = "../../modules/iam"

  cluster_name            = var.cluster_name
  create_base_roles       = false
  create_oidc_provider    = true
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  common_tags             = var.common_tags

  depends_on = [module.eks]
}

# ── ArgoCD Hub ────────────────────────────────────────────────────────────────

module "argocd" {
  source = "../../modules/argocd"

  mode          = "hub"
  chart_version = var.argocd_chart_version
  namespace     = "argocd"

  depends_on = [module.eks]
}

# ── Transit Gateway ───────────────────────────────────────────────────────────
# Replaces VPC peering. All cross-account TGW resources (attachments, routes,
# RAM shares, SG rules) are created from this workspace using aliased providers.

module "transit_gateway" {
  source = "../../modules/transit-gateway"

  providers = {
    aws.hub  = aws.hub
    aws.prod = aws.prod
  }

  # Hub inputs
  hub_vpc_id                  = module.vpc.vpc_id
  hub_vpc_cidr                = module.vpc.vpc_cidr_block
  hub_private_subnet_ids      = module.vpc.private_subnet_ids
  hub_private_route_table_ids = module.vpc.private_route_table_ids

  # Prod inputs (from prod remote state)
  prod_vpc_id                  = data.terraform_remote_state.prod.outputs.vpc_id
  prod_vpc_cidr                = data.terraform_remote_state.prod.outputs.vpc_cidr
  prod_private_subnet_ids      = data.terraform_remote_state.prod.outputs.private_subnet_ids
  prod_private_route_table_ids = data.terraform_remote_state.prod.outputs.private_route_table_ids
  prod_cluster_sg_id           = data.terraform_remote_state.prod.outputs.cluster_security_group_id

  prod_account_id = var.prod_account_id
  aws_region      = var.aws_region
  common_tags     = var.common_tags

  depends_on = [module.vpc]
}

# ── Wait for ArgoCD to be ready before creating cluster secrets ───────────────

resource "time_sleep" "wait_for_argocd" {
  create_duration = "60s"

  depends_on = [module.argocd]
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────
# Provisions NLBs (for ArgoCD, Istio) and ALBs (for app Ingress resources)
# using Pod Identity. Must be ready before ArgoCD's LoadBalancer Service is
# reconciled so the controller's webhook can annotate it correctly.

module "aws_load_balancer_controller" {
  source = "../../modules/aws-load-balancer-controller"

  cluster_name  = var.cluster_name
  vpc_id        = module.vpc.vpc_id
  account_id    = var.hub_account_id
  region        = var.aws_region
  chart_version = var.lbc_chart_version
  common_tags   = var.common_tags

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
