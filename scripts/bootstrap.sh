#!/usr/bin/env bash
# bootstrap.sh — Create S3 state bucket and DynamoDB lock table
# Usage: ./scripts/bootstrap.sh [aws-region]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_DIR="$ROOT_DIR/bootstrap"

AWS_REGION="${1:-eu-west-2}"

echo "==> Bootstrapping Terraform state backend in $AWS_REGION"

cd "$BOOTSTRAP_DIR"

terraform init
terraform apply -var "aws_region=$AWS_REGION" -auto-approve

BUCKET_NAME=$(terraform output -raw state_bucket_name)
LOCK_TABLE=$(terraform output -raw lock_table_name)

echo ""
echo "==> Bootstrap complete!"
echo "    State bucket:  $BUCKET_NAME"
echo "    Lock table:    $LOCK_TABLE"
echo "    Region:        $AWS_REGION"
echo ""
echo "==> Next: update REPLACE_WITH_STATE_BUCKET in all backend.tf and terraform.tfvars files:"
echo "    sed -i '' 's/REPLACE_WITH_STATE_BUCKET/$BUCKET_NAME/g' \\"
echo "      $ROOT_DIR/envs/prod/backend.tf \\"
echo "      $ROOT_DIR/envs/hub/backend.tf \\"
echo "      $ROOT_DIR/envs/prod-data/backend.tf \\"
echo "      $ROOT_DIR/envs/hub/terraform.tfvars"
echo ""
echo "    Or run:"
echo "    BUCKET=$BUCKET_NAME && find $ROOT_DIR/envs -name '*.tf' -o -name '*.tfvars' | xargs sed -i '' \"s/REPLACE_WITH_STATE_BUCKET/\$BUCKET/g\""
