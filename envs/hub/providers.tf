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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

# Default provider — hub account.
# Used by all existing hub resources (VPC, EKS, IAM, ArgoCD, Karpenter).
provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.hub_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

# Aliased hub provider — passed explicitly into the transit-gateway module.
# Targets the same hub account as the default provider above.
provider "aws" {
  alias  = "hub"
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.hub_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

# Dev spoke provider — used by transit-gateway module to create attachments
# and routes in the dev account.
provider "aws" {
  alias  = "dev"
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.dev_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

# Prod spoke provider — used by transit-gateway module to create attachments
# and routes in the prod account.
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

# Data spoke provider — used by transit-gateway module to create attachments
# and routes in the data account.
provider "aws" {
  alias  = "data"
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:iam::${var.data_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = var.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region, "--role-arn", "arn:aws:iam::${var.hub_account_id}:role/OrganizationAccountAccessRole"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region, "--role-arn", "arn:aws:iam::${var.hub_account_id}:role/OrganizationAccountAccessRole"]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region, "--role-arn", "arn:aws:iam::${var.hub_account_id}:role/OrganizationAccountAccessRole"]
  }
}
