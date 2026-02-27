aws_region   = "us-east-1"
cluster_name = "eks-prod"

vpc_cidr             = "10.2.0.0/16"
public_subnet_cidrs  = ["10.2.0.0/24", "10.2.1.0/24"]
private_subnet_cidrs = ["10.2.10.0/24", "10.2.11.0/24"]

kubernetes_version   = "1.30"
node_instance_type   = "t3.large"
node_desired_size    = 2
node_min_size        = 2
node_max_size        = 6

argocd_chart_version = "7.8.26"

common_tags = {
  Project     = "eks-hub-spoke"
  Environment = "prod"
  ManagedBy   = "terraform"
}
