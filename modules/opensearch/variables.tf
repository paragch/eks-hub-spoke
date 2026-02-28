variable "cluster_name" {
  description = "Name prefix for all OpenSearch resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID in which the OpenSearch domain will be placed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the OpenSearch VPC endpoint"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the OpenSearch HTTPS endpoint (port 443)"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "opensearch_version" {
  description = "OpenSearch version"
  type        = string
  default     = "2.11"
}

variable "instance_type" {
  description = "OpenSearch instance type"
  type        = string
  default     = "t3.medium.search"
}

variable "instance_count" {
  description = "Number of data nodes in the OpenSearch cluster"
  type        = number
  default     = 2
}

variable "volume_size" {
  description = "EBS volume size (GiB) per OpenSearch data node"
  type        = number
  default     = 20
}

variable "db_writer_role_arn" {
  description = "IAM role ARN for the db-writer microservice (granted es:ESHttp* access)"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all created resources"
  type        = map(string)
  default     = {}
}
