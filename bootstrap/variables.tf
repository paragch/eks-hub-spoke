variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "state_bucket_prefix" {
  description = "Prefix for the S3 state bucket name"
  type        = string
  default     = "eks-hub-spoke-tfstate"
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "eks-hub-spoke-tfstate-lock"
}
