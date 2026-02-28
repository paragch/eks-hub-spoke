aws_region   = "eu-west-2"
cluster_name = "eks-dev"

# Replace with the actual dev account ID from: terraform output -chdir=envs/accounts dev_account_id
account_id = "REPLACE_WITH_DEV_ACCOUNT_ID"

vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.0.0/24", "10.1.1.0/24"]
private_subnet_cidrs = ["10.1.10.0/24", "10.1.11.0/24"]

kubernetes_version   = "1.32"
node_instance_type   = "t3.medium"
node_desired_size    = 2
node_min_size        = 2
node_max_size        = 4

argocd_chart_version = "7.8.26"

common_tags = {
  Project     = "eks-hub-spoke"
  Environment = "dev"
  ManagedBy   = "terraform"
}
