#!/usr/bin/env bash
# teardown.sh — Destroy all environments in reverse order: hub → dev → prod
# Hub must be destroyed first since it depends on spoke state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "WARNING: This will DESTROY all three EKS clusters and associated resources!"
read -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

destroy_env() {
  local ENV="$1"
  local DIR="$ROOT_DIR/envs/$ENV"

  echo ""
  echo "======================================================="
  echo "  Destroying: $ENV"
  echo "======================================================="

  cd "$DIR"
  terraform init -reconfigure
  terraform destroy -auto-approve
}

destroy_env hub
destroy_env dev
destroy_env prod

echo ""
echo "==> All environments destroyed."
echo "    Note: The S3 state bucket and DynamoDB lock table were NOT destroyed."
echo "    To remove them: cd bootstrap && terraform destroy"
