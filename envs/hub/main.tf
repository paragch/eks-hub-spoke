data "aws_availability_zones" "available" {
  state = "available"
}

# ── Remote state from dev spoke ───────────────────────────────────────────────

data "terraform_remote_state" "dev" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/terraform.tfstate"
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

# ── VPC Peering: hub ↔ dev ────────────────────────────────────────────────────

module "peering_hub_dev" {
  source = "../../modules/vpc-peering"

  peering_name             = "hub-to-dev"
  requester_vpc_id         = module.vpc.vpc_id
  requester_vpc_cidr       = module.vpc.vpc_cidr_block
  requester_route_table_ids = module.vpc.private_route_table_ids
  accepter_vpc_id          = data.terraform_remote_state.dev.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.dev.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.dev.outputs.private_route_table_ids
  accepter_cluster_sg_id   = data.terraform_remote_state.dev.outputs.cluster_security_group_id
  common_tags              = var.common_tags

  depends_on = [module.vpc]
}

# ── VPC Peering: hub ↔ prod ───────────────────────────────────────────────────

module "peering_hub_prod" {
  source = "../../modules/vpc-peering"

  peering_name             = "hub-to-prod"
  requester_vpc_id         = module.vpc.vpc_id
  requester_vpc_cidr       = module.vpc.vpc_cidr_block
  requester_route_table_ids = module.vpc.private_route_table_ids
  accepter_vpc_id          = data.terraform_remote_state.prod.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.prod.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.prod.outputs.private_route_table_ids
  accepter_cluster_sg_id   = data.terraform_remote_state.prod.outputs.cluster_security_group_id
  common_tags              = var.common_tags

  depends_on = [module.vpc]
}

# ── Wait for ArgoCD to be ready before creating cluster secrets ───────────────

resource "time_sleep" "wait_for_argocd" {
  create_duration = "60s"

  depends_on = [module.argocd]
}
