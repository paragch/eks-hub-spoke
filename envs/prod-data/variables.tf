variable "state_bucket" {
  description = "S3 bucket name for Terraform remote state (set by startup.sh)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "account_id" {
  description = "AWS account ID for the prod-data member account"
  type        = string
}

variable "prod_account_id" {
  description = "AWS account ID for the prod member account (microservice runs there)"
  type        = string
}

variable "prod_cluster_endpoint" {
  description = "eks-prod cluster API endpoint (from: terraform output -chdir=envs/prod -raw cluster_endpoint)"
  type        = string
}

variable "prod_cluster_ca_data" {
  description = "eks-prod cluster CA certificate data, base64-encoded (from: terraform output -chdir=envs/prod -raw cluster_certificate_authority_data)"
  type        = string
}

variable "prod_cluster_name" {
  description = "eks-prod cluster name (from: terraform output -chdir=envs/prod -raw cluster_name)"
  type        = string
  default     = "eks-prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR block for the prod-data account"
  type        = string
  default     = "10.4.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

# ── OpenSearch variables ───────────────────────────────────────────────────────

variable "opensearch_version" {
  description = "OpenSearch version"
  type        = string
  default     = "2.11"
}

variable "opensearch_instance_type" {
  description = "OpenSearch data node instance type"
  type        = string
  default     = "t3.medium.search"
}

variable "opensearch_instance_count" {
  description = "Number of OpenSearch data nodes"
  type        = number
  default     = 2
}

# ── Aurora variables ───────────────────────────────────────────────────────────

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.1"
}

variable "aurora_instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "aurora_db_name" {
  description = "Initial database name for Aurora"
  type        = string
}

variable "aurora_db_username" {
  description = "Master username for the Aurora cluster"
  type        = string
}

variable "aurora_db_password" {
  description = "Master password for the Aurora cluster"
  type        = string
  sensitive   = true
}

# ── Neptune variables ──────────────────────────────────────────────────────────

variable "neptune_engine_version" {
  description = "Neptune engine version"
  type        = string
  default     = "1.3.1.0"
}

variable "neptune_instance_class" {
  description = "Neptune instance class"
  type        = string
  default     = "db.t3.medium"
}

# ── Microservice variables ─────────────────────────────────────────────────────

variable "mq_username" {
  description = "Amazon MQ admin username (mirrors prod)"
  type        = string
  default     = "admin"
}

variable "mq_password" {
  description = "Amazon MQ admin password (mirrors prod)"
  type        = string
  sensitive   = true
}

variable "db_writer_image" {
  description = "Container image for the db-writer microservice"
  type        = string
  default     = "REPLACE_WITH_DB_WRITER_IMAGE"
}

variable "kafka_mq_bridge_image" {
  description = "Container image for the kafka-mq-bridge microservice"
  type        = string
  default     = "REPLACE_WITH_BRIDGE_IMAGE"
}

variable "common_tags" {
  description = "Common tags applied to all created resources"
  type        = map(string)
  default     = {}
}
