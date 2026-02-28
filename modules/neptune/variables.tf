variable "cluster_name" {
  description = "Name prefix for all Neptune resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID in which the Neptune cluster will be placed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Neptune subnet group"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach Neptune on port 8182 (Gremlin/Bolt/SPARQL)"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "engine_version" {
  description = "Neptune engine version"
  type        = string
  default     = "1.3.1.0"
}

variable "instance_class" {
  description = "Neptune instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "instance_count" {
  description = "Number of Neptune instances"
  type        = number
  default     = 1
}

variable "common_tags" {
  description = "Common tags applied to all created resources"
  type        = map(string)
  default     = {}
}
