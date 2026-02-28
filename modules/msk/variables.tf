variable "cluster_name" {
  description = "EKS cluster name — used to derive MSK resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the MSK brokers will be placed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for broker placement. Must have at least number_of_broker_nodes entries (one subnet per broker per AZ)."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used to allow Kafka IAM/TLS traffic from EKS pods"
  type        = string
}

variable "kafka_version" {
  description = "Apache Kafka version for the MSK cluster"
  type        = string
  default     = "3.6.0"
}

variable "number_of_broker_nodes" {
  description = "Total number of broker nodes. Must equal the number of client_subnets (one broker per AZ)."
  type        = number
  default     = 2
}

variable "broker_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.m5.large"
}

variable "broker_volume_size" {
  description = "EBS volume size per broker node (GiB)"
  type        = number
  default     = 100
}

variable "common_tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}
