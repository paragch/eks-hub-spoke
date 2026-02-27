variable "peering_name" {
  description = "Name for the VPC peering connection"
  type        = string
}

variable "requester_vpc_id" {
  description = "VPC ID of the peering requester (hub)"
  type        = string
}

variable "requester_vpc_cidr" {
  description = "CIDR block of the requester VPC"
  type        = string
}

variable "requester_route_table_ids" {
  description = "Route table IDs in the requester VPC to add routes to"
  type        = list(string)
}

variable "accepter_vpc_id" {
  description = "VPC ID of the peering accepter (spoke)"
  type        = string
}

variable "accepter_vpc_cidr" {
  description = "CIDR block of the accepter VPC"
  type        = string
}

variable "accepter_route_table_ids" {
  description = "Route table IDs in the accepter VPC to add routes to"
  type        = list(string)
}

variable "accepter_cluster_sg_id" {
  description = "Security group ID of the spoke cluster (to allow hub to connect on 443)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
