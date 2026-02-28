terraform {
  required_version = ">= 1.6"

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

# ── Default provider — prod-data account ──────────────────────────────────────
# Creates the databases (OpenSearch, Aurora, Neptune), the prod-data VPC,
# and the requester side of the VPC peering connection.

provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

# ── aws.prod — prod account ────────────────────────────────────────────────────
# Accepts the VPC peering connection, adds routes on the prod side,
# creates the db-writer IAM role + Pod Identity association.

provider "aws" {
  alias  = "prod"
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

# ── kubernetes — eks-prod cluster ─────────────────────────────────────────────
# Deploys the db-writer namespace, service account, ConfigMap, Secrets,
# and Deployment onto the existing eks-prod cluster in the prod account.
#
# The cluster endpoint and CA are passed as variables because Terraform
# provider configurations are evaluated before data sources. Populate them
# from the prod workspace outputs:
#   prod_cluster_endpoint = $(terraform output -chdir=envs/prod -raw cluster_endpoint)
#   prod_cluster_ca_data  = $(terraform output -chdir=envs/prod -raw cluster_certificate_authority_data)
#   prod_cluster_name     = $(terraform output -chdir=envs/prod -raw cluster_name)

provider "kubernetes" {
  host                   = var.prod_cluster_endpoint
  cluster_ca_certificate = base64decode(var.prod_cluster_ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", var.prod_cluster_name,
      "--region", var.aws_region,
      "--role-arn", "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole"
    ]
  }
}
