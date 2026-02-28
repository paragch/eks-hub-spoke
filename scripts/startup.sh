#!/usr/bin/env bash
# startup.sh — Full environment startup:
#   1. Bootstrap S3 state backend + DynamoDB lock table
#   2. Create hub / dev / prod AWS member accounts via Organizations
#   3. Wait for OrganizationAccountAccessRole to become assumable
#   4. Deploy dev + prod EKS clusters in parallel
#   5. Deploy hub EKS cluster + Transit Gateway
#   6. Update local kubeconfig for all clusters
#
# Prerequisites:
#   • AWS CLI configured with management account credentials
#   • Terraform >= 1.6 installed
#   • jq installed
#   • envs/accounts/terraform.tfvars — fill in hub/dev/prod email addresses
#     (REPLACE_WITH_*_ACCOUNT_EMAIL) before running this script
#
# Usage:
#   ./scripts/startup.sh               # interactive — shows plan before each apply
#   ./scripts/startup.sh --auto-approve  # non-interactive / CI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AUTO_APPROVE="${1:-}"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_warn() { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Portable sed -i ────────────────────────────────────────────────────────────
sed_inplace() {
  local pattern="$1"; shift
  if sed --version 2>&1 | grep -q GNU 2>/dev/null; then
    sed -i "$pattern" "$@"
  else
    sed -i '' "$pattern" "$@"
  fi
}

# ── Terraform apply wrapper ────────────────────────────────────────────────────
tf_apply() {
  local dir="$1"
  cd "$dir"
  terraform init -reconfigure
  if [[ "$AUTO_APPROVE" == "--auto-approve" ]]; then
    terraform apply -auto-approve
  else
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
  fi
}

# ── 0. Prerequisite checks ─────────────────────────────────────────────────────
check_prereqs() {
  log_step "Checking prerequisites"

  local missing=0
  for cmd in terraform aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_err "$cmd is not installed or not in PATH"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1

  if ! aws sts get-caller-identity &>/dev/null; then
    log_err "AWS credentials are not configured or are invalid"
    exit 1
  fi
  log_ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

  # Ensure account email placeholders have been filled in
  local accounts_tfvars="$ROOT_DIR/envs/accounts/terraform.tfvars"
  if grep -q 'REPLACE_WITH_.*_ACCOUNT_EMAIL' "$accounts_tfvars"; then
    log_err "Fill in the email addresses in envs/accounts/terraform.tfvars before running startup."
    echo "  Edit: $accounts_tfvars"
    exit 1
  fi

  log_ok "All prerequisites satisfied"
}

# ── 1. Bootstrap state backend ────────────────────────────────────────────────
bootstrap_state() {
  log_step "Step 1/5 — Bootstrap Terraform state backend (S3 + DynamoDB)"

  local sample_backend="$ROOT_DIR/envs/dev/backend.tf"
  if grep -q 'REPLACE_WITH_STATE_BUCKET' "$sample_backend"; then
    log_ok "Running bootstrap..."
    cd "$ROOT_DIR/bootstrap"
    terraform init -reconfigure
    terraform apply -auto-approve

    BUCKET_NAME=$(terraform output -raw state_bucket_name)
    log_ok "State bucket created: $BUCKET_NAME"

    log_ok "Substituting bucket name in all backend.tf and terraform.tfvars files..."
    find "$ROOT_DIR/envs" -name "backend.tf" -o -name "terraform.tfvars" | \
      xargs grep -l 'REPLACE_WITH_STATE_BUCKET' 2>/dev/null | \
      while read -r f; do
        sed_inplace "s/REPLACE_WITH_STATE_BUCKET/$BUCKET_NAME/g" "$f"
        echo "    Updated: $f"
      done
  else
    BUCKET_NAME=$(awk -F'"' '/bucket/{print $2; exit}' "$sample_backend")
    log_ok "State bucket already configured ($BUCKET_NAME) — skipping bootstrap"
  fi
}

# ── 2. Create member accounts ─────────────────────────────────────────────────
create_accounts() {
  log_step "Step 2/5 — Create AWS Organizations member accounts"

  tf_apply "$ROOT_DIR/envs/accounts"

  HUB_ACCOUNT_ID=$(terraform output -raw hub_account_id)
  DEV_ACCOUNT_ID=$(terraform output -raw dev_account_id)
  PROD_ACCOUNT_ID=$(terraform output -raw prod_account_id)

  log_ok "hub  account: $HUB_ACCOUNT_ID"
  log_ok "dev  account: $DEV_ACCOUNT_ID"
  log_ok "prod account: $PROD_ACCOUNT_ID"

  log_ok "Writing account IDs into terraform.tfvars files..."
  sed_inplace "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV_ACCOUNT_ID/g"   "$ROOT_DIR/envs/dev/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PROD_ACCOUNT_ID/g" "$ROOT_DIR/envs/prod/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_HUB_ACCOUNT_ID/$HUB_ACCOUNT_ID/g"   "$ROOT_DIR/envs/hub/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV_ACCOUNT_ID/g"   "$ROOT_DIR/envs/hub/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PROD_ACCOUNT_ID/g" "$ROOT_DIR/envs/hub/terraform.tfvars"
  log_ok "tfvars updated"
}

# ── 3. Wait for OrganizationAccountAccessRole ─────────────────────────────────
wait_for_iam_roles() {
  log_step "Step 3/5 — Waiting for OrganizationAccountAccessRole to propagate"

  local accounts=("$HUB_ACCOUNT_ID" "$DEV_ACCOUNT_ID" "$PROD_ACCOUNT_ID")
  for account in "${accounts[@]}"; do
    local role_arn="arn:aws:iam::${account}:role/OrganizationAccountAccessRole"
    echo "  Polling: $role_arn"
    local attempt=0
    until aws sts assume-role \
          --role-arn "$role_arn" \
          --role-session-name startup-check \
          --duration-seconds 900 \
          &>/dev/null; do
      attempt=$((attempt + 1))
      if [[ $attempt -ge 30 ]]; then
        log_err "Timed out (${attempt}x10 s) waiting for $role_arn"
        exit 1
      fi
      echo "    Not ready yet — retrying in 10 s... (attempt $attempt/30)"
      sleep 10
    done
    log_ok "Assumable: $role_arn"
  done
}

# ── 4. Apply dev + prod in parallel ───────────────────────────────────────────
apply_spokes() {
  log_step "Step 4/5 — Deploy dev and prod clusters (parallel)"

  local dev_log="$ROOT_DIR/.startup-dev.log"
  local prod_log="$ROOT_DIR/.startup-prod.log"
  : > "$dev_log"; : > "$prod_log"

  echo "  Logs: $dev_log  |  $prod_log"

  (
    cd "$ROOT_DIR/envs/dev"
    terraform init -reconfigure >> "$dev_log" 2>&1
    terraform apply -auto-approve >> "$dev_log" 2>&1
    echo "==> dev apply complete" >> "$dev_log"
  ) &
  local dev_pid=$!

  (
    cd "$ROOT_DIR/envs/prod"
    terraform init -reconfigure >> "$prod_log" 2>&1
    terraform apply -auto-approve >> "$prod_log" 2>&1
    echo "==> prod apply complete" >> "$prod_log"
  ) &
  local prod_pid=$!

  echo "  Waiting for dev (PID $dev_pid) and prod (PID $prod_pid)..."
  local dev_rc=0 prod_rc=0
  wait "$dev_pid"  || dev_rc=$?
  wait "$prod_pid" || prod_rc=$?

  if [[ $dev_rc -ne 0 ]]; then
    log_err "Dev apply failed — see $dev_log"
    tail -30 "$dev_log" >&2
    exit 1
  fi
  if [[ $prod_rc -ne 0 ]]; then
    log_err "Prod apply failed — see $prod_log"
    tail -30 "$prod_log" >&2
    exit 1
  fi

  log_ok "dev and prod clusters deployed"
}

# ── 5. Apply hub ──────────────────────────────────────────────────────────────
apply_hub() {
  log_step "Step 5/5 — Deploy hub cluster + Transit Gateway"
  tf_apply "$ROOT_DIR/envs/hub"
  log_ok "Hub cluster deployed"
}

# ── Update kubeconfigs ────────────────────────────────────────────────────────
update_kubeconfigs() {
  log_step "Updating kubeconfigs"
  "$SCRIPT_DIR/get-kubeconfigs.sh"
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}#######################################################${NC}"
echo -e "${CYAN}#        eks-hub-spoke  STARTUP                       #${NC}"
echo -e "${CYAN}#######################################################${NC}"

if [[ "$AUTO_APPROVE" != "--auto-approve" ]]; then
  echo ""
  echo "This script will:"
  echo "  1. Create an S3 state bucket + DynamoDB lock table"
  echo "  2. Provision hub / dev / prod AWS accounts via Organizations"
  echo "  3. Deploy three EKS clusters (hub, dev, prod)"
  echo "  4. Set up Transit Gateway cross-account connectivity"
  echo "  5. Register dev + prod clusters in ArgoCD"
  echo ""
  read -rp "Continue? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

check_prereqs
bootstrap_state
create_accounts
wait_for_iam_roles
apply_spokes
apply_hub
update_kubeconfigs

echo ""
log_ok "Startup complete — all clusters are running."
echo ""
echo "    Cluster  Account"
echo "    -------  -------"
echo "    eks-hub  $HUB_ACCOUNT_ID"
echo "    eks-dev  $DEV_ACCOUNT_ID"
echo "    eks-prod $PROD_ACCOUNT_ID"
echo ""
echo "  kubectl config get-contexts   # list available contexts"
