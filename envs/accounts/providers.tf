terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Runs as the management account — no assume_role needed.
# Ensure Terraform is executed with management-account credentials
# (e.g. AWS_PROFILE pointing to the management account).
provider "aws" {
  region = var.aws_region
}
