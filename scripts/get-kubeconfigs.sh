#!/usr/bin/env bash
# get-kubeconfigs.sh — Update kubeconfig for all three clusters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Read region from hub tfvars (default eu-west-2)
AWS_REGION=$(grep 'aws_region' "$ROOT_DIR/envs/hub/terraform.tfvars" | awk -F'"' '{print $2}' || echo "eu-west-2")

CLUSTERS=(
  "eks-hub:hub"
  "eks-dev:dev"
  "eks-prod:prod"
)

for entry in "${CLUSTERS[@]}"; do
  CLUSTER="${entry%%:*}"
  ALIAS="${entry##*:}"

  echo "==> Updating kubeconfig for $CLUSTER (alias: $ALIAS)"
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER" \
    --alias "$ALIAS"
done

echo ""
echo "==> Done! Available contexts:"
kubectl config get-contexts
