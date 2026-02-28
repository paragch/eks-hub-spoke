variable "cluster_name" {
  description = "EKS cluster name — used to derive Amazon MQ resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Amazon MQ brokers will be placed"
  type        = string
}

variable "vpc_cidr" {
  description = "Local VPC CIDR — used to restrict the web console port to the local VPC"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for broker placement. ACTIVE_STANDBY_MULTI_AZ requires at least 2 subnets (one per AZ); SINGLE_INSTANCE uses the first subnet."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach broker message ports (5671, 61617, 61614). Defaults to 10.0.0.0/8 to cover all four VPCs connected via Transit Gateway."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "engine_type" {
  description = "Amazon MQ broker engine type"
  type        = string
  default     = "ActiveMQ"
}

variable "engine_version" {
  description = "ActiveMQ engine version"
  type        = string
  default     = "5.18.3"
}

variable "instance_type" {
  description = "Amazon MQ broker instance type"
  type        = string
  default     = "mq.m5.large"
}

variable "deployment_mode" {
  description = "Broker deployment mode. ACTIVE_STANDBY_MULTI_AZ provides HA across two AZs; SINGLE_INSTANCE is suitable for non-production."
  type        = string
  default     = "ACTIVE_STANDBY_MULTI_AZ"

  validation {
    condition     = contains(["SINGLE_INSTANCE", "ACTIVE_STANDBY_MULTI_AZ"], var.deployment_mode)
    error_message = "deployment_mode must be SINGLE_INSTANCE or ACTIVE_STANDBY_MULTI_AZ."
  }
}

variable "mq_username" {
  description = "Username for the Amazon MQ admin user"
  type        = string
  default     = "admin"
}

variable "mq_password" {
  description = "Password for the Amazon MQ admin user. Must be 12–250 characters. Stored as a sensitive value in Terraform state (S3, AES256 encrypted)."
  type        = string
  sensitive   = true
}

variable "common_tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}
