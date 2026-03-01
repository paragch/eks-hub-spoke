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

# ── Cross-account identifiers ─────────────────────────────────────────────────

variable "prod_account_id" {
  description = "AWS account ID of the prod member account"
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
