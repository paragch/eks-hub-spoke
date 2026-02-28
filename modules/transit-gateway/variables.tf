# ── Hub VPC inputs ────────────────────────────────────────────────────────────

variable "hub_vpc_id" {
  description = "VPC ID of the hub cluster"
  type        = string
}

variable "hub_vpc_cidr" {
  description = "CIDR block of the hub VPC"
  type        = string
}

variable "hub_private_subnet_ids" {
  description = "Private subnet IDs in the hub VPC (used for TGW attachment)"
  type        = list(string)
}

variable "hub_private_route_table_ids" {
  description = "Private route table IDs in the hub VPC"
  type        = list(string)
}

# ── Dev VPC inputs ────────────────────────────────────────────────────────────

variable "dev_vpc_id" {
  description = "VPC ID of the dev cluster"
  type        = string
}

variable "dev_vpc_cidr" {
  description = "CIDR block of the dev VPC"
  type        = string
}

variable "dev_private_subnet_ids" {
  description = "Private subnet IDs in the dev VPC (used for TGW attachment)"
  type        = list(string)
}

variable "dev_private_route_table_ids" {
  description = "Private route table IDs in the dev VPC"
  type        = list(string)
}

variable "dev_cluster_sg_id" {
  description = "Cluster security group ID in the dev account (to allow hub API access)"
  type        = string
}

# ── Prod VPC inputs ───────────────────────────────────────────────────────────

variable "prod_vpc_id" {
  description = "VPC ID of the prod cluster"
  type        = string
}

variable "prod_vpc_cidr" {
  description = "CIDR block of the prod VPC"
  type        = string
}

variable "prod_private_subnet_ids" {
  description = "Private subnet IDs in the prod VPC (used for TGW attachment)"
  type        = list(string)
}

variable "prod_private_route_table_ids" {
  description = "Private route table IDs in the prod VPC"
  type        = list(string)
}

variable "prod_cluster_sg_id" {
  description = "Cluster security group ID in the prod account (to allow hub API access)"
  type        = string
}

# ── Data VPC inputs ───────────────────────────────────────────────────────────

variable "data_vpc_id" {
  description = "VPC ID of the data cluster"
  type        = string
}

variable "data_vpc_cidr" {
  description = "CIDR block of the data VPC"
  type        = string
}

variable "data_private_subnet_ids" {
  description = "Private subnet IDs in the data VPC (used for TGW attachment)"
  type        = list(string)
}

variable "data_private_route_table_ids" {
  description = "Private route table IDs in the data VPC"
  type        = list(string)
}

variable "data_cluster_sg_id" {
  description = "Cluster security group ID in the data account (to allow hub API access)"
  type        = string
}

# ── Cross-account identifiers ─────────────────────────────────────────────────

variable "dev_account_id" {
  description = "AWS account ID of the dev member account"
  type        = string
}

variable "prod_account_id" {
  description = "AWS account ID of the prod member account"
  type        = string
}

variable "data_account_id" {
  description = "AWS account ID of the data member account"
  type        = string
}

# ── Common ────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
