terraform {
  backend "s3" {
    bucket         = "REPLACE_WITH_STATE_BUCKET"
    key            = "prod/terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
    dynamodb_table = "eks-hub-spoke-tfstate-lock"
  }
}
