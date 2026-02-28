#!/usr/bin/env bash
# shutdown.sh — Full environment teardown:
#   1. Destroy hub cluster (Transit Gateway, EKS, ArgoCD, Karpenter)
#   2. Destroy dev and prod clusters in parallel
#   3. Remove hub / dev / prod accounts from Terraform state
#   4. Optionally destroy the S3 state backend (bootstrap)
#
# NOTE: AWS accounts are NOT closed by this script.
#   aws_organizations_account.close_on_deletion = false is intentional.
#   To close the accounts permanently, do so manually from the
#   AWS Organizations console or CLI after running this script.
#
# Usage: ./scripts/shutdown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_warn() { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Confirmation gate ──────────────────────────────────────────────────────────
echo -e "\n${RED}#######################################################${NC}"
echo -e "${RED}#        eks-hub-spoke  SHUTDOWN                      #${NC}"
echo -e "${RED}#######################################################${NC}"
echo ""
log_warn "This will PERMANENTLY DESTROY:"
echo "    • All three EKS clusters (hub, dev, prod)"
echo "    • Transit Gateway + all VPC attachments and routes"
echo "    • All associated VPCs, IAM roles, and node groups"
echo "    • ArgoCD, Karpenter, and all in-cluster resources"
echo "    • hub / dev / prod Terraform state entries (accounts remain in AWS)"
echo ""
read -rp "Type 'destroy' to confirm: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Helper: destroy one environment ───────────────────────────────────────────
destroy_env() {
  local env="$1"
  local dir="$ROOT_DIR/envs/$env"

  log_step "Destroying: $env"
  cd "$dir"
  terraform init -reconfigure
  terraform destroy -auto-approve
  log_ok "$env destroyed"
}

# ── 1. Destroy hub ─────────────────────────────────────────────────────────────
# Hub must go first: it owns the TGW and reads remote state from dev + prod.
destroy_env hub

# ── 2. Destroy dev + prod in parallel ─────────────────────────────────────────
log_step "Step 2/3 — Destroying dev and prod clusters (parallel)"

dev_log="$ROOT_DIR/.shutdown-dev.log"
prod_log="$ROOT_DIR/.shutdown-prod.log"
: > "$dev_log"; : > "$prod_log"
echo "  Logs: $dev_log  |  $prod_log"

(
  cd "$ROOT_DIR/envs/dev"
  terraform init -reconfigure >> "$dev_log" 2>&1
  terraform destroy -auto-approve >> "$dev_log" 2>&1
  echo "==> dev destroy complete" >> "$dev_log"
) &
dev_pid=$!

(
  cd "$ROOT_DIR/envs/prod"
  terraform init -reconfigure >> "$prod_log" 2>&1
  terraform destroy -auto-approve >> "$prod_log" 2>&1
  echo "==> prod destroy complete" >> "$prod_log"
) &
prod_pid=$!

echo "  Waiting for dev (PID $dev_pid) and prod (PID $prod_pid)..."
dev_rc=0; prod_rc=0
wait "$dev_pid"  || dev_rc=$?
wait "$prod_pid" || prod_rc=$?

if [[ $dev_rc -ne 0 ]]; then
  log_err "Dev destroy failed — see $dev_log"
  tail -30 "$dev_log" >&2
  exit 1
fi
if [[ $prod_rc -ne 0 ]]; then
  log_err "Prod destroy failed — see $prod_log"
  tail -30 "$prod_log" >&2
  exit 1
fi
log_ok "dev and prod clusters destroyed"

# ── 3. Remove accounts from state ─────────────────────────────────────────────
# This removes the aws_organizations_account resources from Terraform state.
# It does NOT close or delete the AWS accounts (close_on_deletion = false).
log_step "Step 3/3 — Removing accounts from Terraform state"
cd "$ROOT_DIR/envs/accounts"
terraform init -reconfigure
terraform destroy -auto-approve
log_ok "Accounts removed from state"

echo ""
log_warn "The hub / dev / prod AWS accounts still exist in AWS Organizations."
echo "  To close them permanently, run:"
echo "    aws organizations close-account --account-id <ACCOUNT_ID>"
echo "  or use the AWS Organizations console."

# ── Optional: destroy state backend ───────────────────────────────────────────
echo ""
read -rp "Also destroy the S3 state backend and DynamoDB table? [y/N] " yn
if [[ "${yn,,}" == "y" ]]; then
  log_warn "Destroying the state backend will make it impossible to recover any Terraform state."
  read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM2
  if [[ "$CONFIRM2" == "yes" ]]; then
    log_step "Destroying state backend (bootstrap)"
    cd "$ROOT_DIR/bootstrap"
    terraform init
    # Force-empty the bucket first so Terraform can delete it
    BUCKET=$(terraform output -raw state_bucket_name 2>/dev/null || true)
    if [[ -n "$BUCKET" ]]; then
      log_ok "Emptying bucket: $BUCKET"
      aws s3 rm "s3://$BUCKET" --recursive
      # Remove all versions and delete markers so versioned bucket can be destroyed
      aws s3api list-object-versions --bucket "$BUCKET" --output json 2>/dev/null | \
        jq -r '.Versions[]? | "\(.Key) \(.VersionId)"' | \
        while read -r key ver; do
          aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" &>/dev/null
        done
      aws s3api list-object-versions --bucket "$BUCKET" --output json 2>/dev/null | \
        jq -r '.DeleteMarkers[]? | "\(.Key) \(.VersionId)"' | \
        while read -r key ver; do
          aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" &>/dev/null
        done
    fi
    terraform destroy -auto-approve
    log_ok "State backend destroyed"
  else
    log_ok "Skipping state backend destruction"
  fi
else
  log_ok "State backend preserved"
  echo "    To remove it later: cd bootstrap && terraform destroy"
fi

echo ""
log_ok "Shutdown complete."
