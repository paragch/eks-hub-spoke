#!/usr/bin/env bash
# apply-all.sh — Apply all environments in the correct order: dev → prod → hub
# Hub's terraform_remote_state requires dev + prod state to exist first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

apply_env() {
  local ENV="$1"
  local DIR="$ROOT_DIR/envs/$ENV"

  echo ""
  echo "======================================================="
  echo "  Applying: $ENV"
  echo "======================================================="

  cd "$DIR"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan
}

apply_env dev
apply_env prod
apply_env hub

echo ""
echo "==> All environments applied successfully!"
echo "    Run ./scripts/get-kubeconfigs.sh to update your kubeconfig"
