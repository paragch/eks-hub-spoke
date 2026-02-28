variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "emr_job_execution_role_arn" {
  description = "ARN of the EMR job execution IAM role — reused by JupyterHub single-user pods so notebooks can access S3 and MSK with the same permissions as EMR jobs"
  type        = string
}

variable "chart_version" {
  description = "JupyterHub Helm chart version"
  type        = string
  default     = "4.1.0"
}

variable "singleuser_image" {
  description = "Container image for single-user notebook servers (must include PySpark)"
  type        = string
  default     = "quay.io/jupyter/pyspark-notebook"
}

variable "singleuser_image_tag" {
  description = "Image tag for the single-user notebook server"
  type        = string
  default     = "2024-12-09"
}

variable "kafka_bootstrap_brokers" {
  description = "MSK IAM bootstrap broker string — injected as KAFKA_BOOTSTRAP_SERVERS env var in notebook pods"
  type        = string
  default     = ""
}

variable "emr_virtual_cluster_id" {
  description = "EMR virtual cluster ID — injected as EMR_VIRTUAL_CLUSTER_ID env var so notebooks can submit EMR jobs"
  type        = string
  default     = ""
}

variable "spark_log_bucket" {
  description = "S3 bucket name for Spark event logs (used to set SPARK_LOG_DIR env var in notebook pods)"
  type        = string
  default     = ""
}

variable "storage_class" {
  description = "Kubernetes StorageClass for notebook persistent volumes (requires aws-ebs-csi-driver addon)"
  type        = string
  default     = "gp2"
}

variable "storage_capacity" {
  description = "PVC size for each single-user notebook server"
  type        = string
  default     = "10Gi"
}

variable "common_tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}
