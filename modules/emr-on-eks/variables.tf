variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "account_id" {
  description = "AWS account ID where the EKS cluster lives"
  type        = string
}

variable "virtual_cluster_name" {
  description = "Name for the EMR virtual cluster (defaults to <cluster_name>-emr)"
  type        = string
  default     = ""
}

variable "emr_namespace" {
  description = "Kubernetes namespace where EMR jobs will run"
  type        = string
  default     = "emr-jobs"
}

variable "emr_job_service_account" {
  description = "Kubernetes ServiceAccount name used by EMR job runner pods"
  type        = string
  default     = "emr-job-runner"
}

variable "landing_zone_bucket_name" {
  description = "S3 bucket name for the EMR landing zone (parquet source data). Defaults to <cluster_name>-landing-zone-<account_id>."
  type        = string
  default     = ""
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster that EMR jobs write results to. When set, Kafka IAM permissions are added to the job execution role."
  type        = string
  default     = ""
}

variable "msk_bootstrap_brokers" {
  description = "MSK bootstrap broker string (port 9098, IAM/TLS). Stored in a ConfigMap in the emr-jobs namespace for job discoverability."
  type        = string
  default     = ""
}

variable "spark_image" {
  description = "Container image for the Spark History Server (should match the image used for EMR job submissions)"
  type        = string
  default     = "public.ecr.aws/emr-on-eks/spark/emr-7.5.0:latest"
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

locals {
  virtual_cluster_name     = var.virtual_cluster_name != "" ? var.virtual_cluster_name : "${var.cluster_name}-emr"
  landing_zone_bucket_name = var.landing_zone_bucket_name != "" ? var.landing_zone_bucket_name : "${var.cluster_name}-landing-zone-${var.account_id}"

  # MSK resource ARN prefixes — derived from the cluster ARN by replacing
  # ":cluster/" with ":topic/" or ":group/" for topic/group-level IAM grants.
  msk_topic_arn_prefix = var.msk_cluster_arn != "" ? replace(var.msk_cluster_arn, ":cluster/", ":topic/") : ""
  msk_group_arn_prefix = var.msk_cluster_arn != "" ? replace(var.msk_cluster_arn, ":cluster/", ":group/") : ""
}
