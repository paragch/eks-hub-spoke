variable "cluster_name" {
  description = "Name prefix for all Aurora resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID in which the Aurora cluster will be placed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Aurora subnet group"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach Aurora on port 5432"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.1"
}

variable "instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "instance_count" {
  description = "Number of Aurora instances (1 = writer only; 2+ = writer + readers)"
  type        = number
  default     = 2
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_username" {
  description = "Master username for the Aurora cluster"
  type        = string
}

variable "db_password" {
  description = "Master password for the Aurora cluster"
  type        = string
  sensitive   = true
}

variable "common_tags" {
  description = "Common tags applied to all created resources"
  type        = map(string)
  default     = {}
}
