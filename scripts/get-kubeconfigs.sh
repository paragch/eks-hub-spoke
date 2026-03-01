#!/usr/bin/env bash
# get-kubeconfigs.sh — Update kubeconfig for hub and prod clusters.
# Reads account IDs from each environment's terraform.tfvars and passes
# --role-arn so aws eks get-token authenticates to the correct account.
#
# Usage: ./scripts/get-kubeconfigs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'; NC='\033[0m'
log_ok() { echo -e "${GREEN}==> $*${NC}"; }

# ── Read a tfvars value by key ──────────────────────────────────────────────────
tfvar() {
  local file="$1" key="$2"
  grep "^${key}" "$file" | awk -F'"' '{print $2}'
}

# ── Region + cluster names ────────────────────────────────────────────────────
AWS_REGION=$(tfvar "$ROOT_DIR/envs/hub/terraform.tfvars" aws_region)
AWS_REGION="${AWS_REGION:-eu-west-2}"

HUB_CLUSTER=$(tfvar "$ROOT_DIR/envs/hub/terraform.tfvars"  cluster_name)
PROD_CLUSTER=$(tfvar "$ROOT_DIR/envs/prod/terraform.tfvars" cluster_name)

# ── Account IDs ───────────────────────────────────────────────────────────────
HUB_ACCOUNT=$(tfvar "$ROOT_DIR/envs/hub/terraform.tfvars"  hub_account_id)
PROD_ACCOUNT=$(tfvar "$ROOT_DIR/envs/prod/terraform.tfvars" account_id)

if [[ -z "$HUB_ACCOUNT"  || "$HUB_ACCOUNT"  == *REPLACE* || \
      -z "$PROD_ACCOUNT" || "$PROD_ACCOUNT" == *REPLACE* ]]; then
  echo "ERROR: account IDs are not yet set in terraform.tfvars files." >&2
  echo "       Run startup.sh first, or fill in the REPLACE_WITH_* placeholders." >&2
  exit 1
fi

ROLE_SUFFIX="role/OrganizationAccountAccessRole"

# ── Update each kubeconfig ────────────────────────────────────────────────────
declare -A CLUSTERS=(
  ["$HUB_CLUSTER"]="$HUB_ACCOUNT"
  ["$PROD_CLUSTER"]="$PROD_ACCOUNT"
)
declare -A ALIASES=(
  ["$HUB_CLUSTER"]="hub"
  ["$PROD_CLUSTER"]="prod"
)

for cluster in "$HUB_CLUSTER" "$PROD_CLUSTER"; do
  account="${CLUSTERS[$cluster]}"
  alias="${ALIASES[$cluster]}"
  role_arn="arn:aws:iam::${account}:${ROLE_SUFFIX}"

  log_ok "Updating kubeconfig: $cluster (alias: $alias, account: $account)"
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$cluster" \
    --alias "$alias" \
    --role-arn "$role_arn"
done

echo ""
log_ok "Done! Available contexts:"
kubectl config get-contexts
