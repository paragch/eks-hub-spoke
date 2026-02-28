variable "aws_region" {
  description = "AWS region for the Organizations API calls"
  type        = string
  default     = "eu-west-2"
}

variable "hub_account_email" {
  description = "Unique root email address for the hub member account"
  type        = string
}

variable "dev_account_email" {
  description = "Unique root email address for the dev member account"
  type        = string
}

variable "prod_account_email" {
  description = "Unique root email address for the prod member account"
  type        = string
}

variable "data_account_email" {
  description = "Unique root email address for the data member account"
  type        = string
}

variable "prod_data_account_email" {
  description = "Unique root email address for the prod-data member account"
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to all created accounts"
  type        = map(string)
  default = {
    Project   = "eks-hub-spoke"
    ManagedBy = "terraform"
  }
}
