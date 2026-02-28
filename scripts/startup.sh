#!/usr/bin/env bash
# startup.sh — Full environment startup with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. prereqs    Validate tools and unfilled tfvars placeholders
#   2. bootstrap  Create S3 state bucket + DynamoDB lock table
#   3. accounts   Provision hub / dev / prod AWS member accounts
#   4. wait_iam   Poll until OrganizationAccountAccessRole is assumable
#   5. spokes     Deploy dev + prod EKS clusters in parallel
#   6. hub        Deploy hub EKS cluster + Transit Gateway
#   7. kubeconfig Update local kubeconfig for all three clusters
#   ──────────────────────────────────────────────────────────
#
#   Progress is written to .startup-progress in the repo root.
#   Re-running the script resumes from the first incomplete step.
#   Each step is only marked done after it fully succeeds.
#
# Prerequisites:
#   • AWS CLI configured with management account credentials
#   • Terraform >= 1.6, jq
#   • envs/accounts/terraform.tfvars.example — copy to terraform.tfvars and
#     fill in hub/dev/prod email addresses (startup.sh does the copy for you)
#
# Usage:
#   ./scripts/startup.sh                # interactive
#   ./scripts/startup.sh --auto-approve # non-interactive / CI
#   ./scripts/startup.sh --reset        # clear checkpoint and start fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECKPOINT="$ROOT_DIR/.startup-progress"

# Parse flags (order-independent)
AUTO_APPROVE=""
RESET=""
for arg in "$@"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE="1" ;;
    --reset)        RESET="1" ;;
  esac
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GREY='\033[0;90m'; NC='\033[0m'
log_step()  { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()    { echo -e "${GREEN}==> $*${NC}"; }
log_skip()  { echo -e "${GREY}--- $* (already done — skipping)${NC}"; }
log_warn()  { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()   { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Checkpoint helpers ─────────────────────────────────────────────────────────
step_done() { [[ -f "$CHECKPOINT" ]] && grep -qx "$1" "$CHECKPOINT"; }
mark_done() { echo "$1" >> "$CHECKPOINT"; }

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
  if [[ -n "$AUTO_APPROVE" ]]; then
    terraform apply -auto-approve
  else
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
  fi
}

# ── Load already-set values from existing config files ────────────────────────
# Called at startup so skipped steps still have their variables populated.
load_existing_config() {
  # Bucket name — read from any already-configured backend.tf
  local sample="$ROOT_DIR/envs/dev/backend.tf"
  BUCKET_NAME=$(awk -F'"' '/^[[:space:]]*bucket[[:space:]]*=/{print $2; exit}' "$sample" 2>/dev/null || true)
  [[ "${BUCKET_NAME:-}" == "REPLACE_WITH_STATE_BUCKET" ]] && BUCKET_NAME=""

  # Account IDs — read from each env's terraform.tfvars
  HUB_ACCOUNT_ID=$(awk -F'"' '/^hub_account_id/{print $2}' "$ROOT_DIR/envs/hub/terraform.tfvars" 2>/dev/null || true)
  DEV_ACCOUNT_ID=$(awk -F'"' '/^account_id/{print $2}'     "$ROOT_DIR/envs/dev/terraform.tfvars"  2>/dev/null || true)
  PROD_ACCOUNT_ID=$(awk -F'"' '/^account_id/{print $2}'    "$ROOT_DIR/envs/prod/terraform.tfvars" 2>/dev/null || true)

  [[ "${HUB_ACCOUNT_ID:-}"  == *REPLACE* ]] && HUB_ACCOUNT_ID=""
  [[ "${DEV_ACCOUNT_ID:-}"  == *REPLACE* ]] && DEV_ACCOUNT_ID=""
  [[ "${PROD_ACCOUNT_ID:-}" == *REPLACE* ]] && PROD_ACCOUNT_ID=""
}

# ── Initialise tfvars from examples (fresh clone) ─────────────────────────────
# For each env, copy terraform.tfvars.example → terraform.tfvars when the
# latter does not yet exist. Lets startup.sh write bucket names / account IDs
# into the .tfvars without ever modifying the .example templates.
init_tfvars() {
  local changed=0
  for env in accounts dev prod hub; do
    local tfvars="$ROOT_DIR/envs/$env/terraform.tfvars"
    local example="${tfvars}.example"
    if [[ ! -f "$tfvars" && -f "$example" ]]; then
      cp "$example" "$tfvars"
      log_ok "Created envs/$env/terraform.tfvars from .example"
      changed=1
    fi
  done
  if [[ $changed -eq 1 ]]; then
    echo ""
    echo "  Next step: edit envs/accounts/terraform.tfvars and fill in the three"
    echo "  unique email addresses, then re-run this script."
    echo ""
  fi
}

# ── Print checkpoint status ────────────────────────────────────────────────────
show_progress() {
  local steps=("prereqs" "bootstrap" "accounts" "wait_iam" "spokes" "hub" "kubeconfig")
  echo ""
  echo "  Checkpoint: $CHECKPOINT"
  for s in "${steps[@]}"; do
    if step_done "$s"; then
      echo -e "    ${GREEN}✓${NC} $s"
    else
      echo -e "    ${GREY}○${NC} $s"
    fi
  done
  echo ""
}

# ── Step 0: Prerequisites ──────────────────────────────────────────────────────
run_prereqs() {
  if step_done prereqs; then log_skip "Step 0 — Prerequisites"; return; fi
  log_step "Step 0 — Checking prerequisites"

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

  local accounts_tfvars="$ROOT_DIR/envs/accounts/terraform.tfvars"
  if grep -q 'REPLACE_WITH_.*_ACCOUNT_EMAIL' "$accounts_tfvars"; then
    log_err "Fill in the email addresses in envs/accounts/terraform.tfvars before running startup."
    echo "  Edit: $accounts_tfvars"
    exit 1
  fi

  log_ok "All prerequisites satisfied"
  mark_done prereqs
}

# ── Step 1: Bootstrap state backend ───────────────────────────────────────────
run_bootstrap() {
  if step_done bootstrap; then log_skip "Step 1 — Bootstrap (bucket: ${BUCKET_NAME:-unknown})"; return; fi
  log_step "Step 1/6 — Bootstrap Terraform state backend (S3 + DynamoDB)"

  cd "$ROOT_DIR/bootstrap"
  terraform init -reconfigure
  terraform apply -auto-approve

  BUCKET_NAME=$(terraform output -raw state_bucket_name)
  log_ok "State bucket: $BUCKET_NAME"

  # Substitute bucket name in every backend.tf and terraform.tfvars that still
  # has the placeholder. Idempotent — sed silently does nothing if not found.
  log_ok "Substituting REPLACE_WITH_STATE_BUCKET → $BUCKET_NAME ..."
  while IFS= read -r -d '' f; do
    sed_inplace "s/REPLACE_WITH_STATE_BUCKET/$BUCKET_NAME/g" "$f"
    echo "    Updated: $f"
  done < <(find "$ROOT_DIR/envs" \( -name "backend.tf" -o -name "terraform.tfvars" \) -print0)

  mark_done bootstrap
  log_ok "Bootstrap complete"
}

# ── Step 2: Create member accounts ────────────────────────────────────────────
run_accounts() {
  if step_done accounts; then
    log_skip "Step 2 — Accounts (hub: ${HUB_ACCOUNT_ID:-?}  dev: ${DEV_ACCOUNT_ID:-?}  prod: ${PROD_ACCOUNT_ID:-?})"
    return
  fi
  log_step "Step 2/6 — Create AWS Organizations member accounts"

  tf_apply "$ROOT_DIR/envs/accounts"

  HUB_ACCOUNT_ID=$(terraform output -raw hub_account_id)
  DEV_ACCOUNT_ID=$(terraform output -raw dev_account_id)
  PROD_ACCOUNT_ID=$(terraform output -raw prod_account_id)

  log_ok "hub  account: $HUB_ACCOUNT_ID"
  log_ok "dev  account: $DEV_ACCOUNT_ID"
  log_ok "prod account: $PROD_ACCOUNT_ID"

  # Write account IDs into every tfvars file that still has the placeholder.
  # Idempotent — sed does nothing if the pattern is already replaced.
  log_ok "Substituting account ID placeholders in terraform.tfvars files..."
  sed_inplace "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV_ACCOUNT_ID/g"   "$ROOT_DIR/envs/dev/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PROD_ACCOUNT_ID/g" "$ROOT_DIR/envs/prod/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_HUB_ACCOUNT_ID/$HUB_ACCOUNT_ID/g"   "$ROOT_DIR/envs/hub/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV_ACCOUNT_ID/g"   "$ROOT_DIR/envs/hub/terraform.tfvars"
  sed_inplace "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PROD_ACCOUNT_ID/g" "$ROOT_DIR/envs/hub/terraform.tfvars"

  mark_done accounts
  log_ok "Accounts created and tfvars updated"
}

# ── Step 3: Wait for OrganizationAccountAccessRole ────────────────────────────
run_wait_iam() {
  if step_done wait_iam; then log_skip "Step 3 — IAM role propagation"; return; fi
  log_step "Step 3/6 — Waiting for OrganizationAccountAccessRole to propagate"

  for account in "$HUB_ACCOUNT_ID" "$DEV_ACCOUNT_ID" "$PROD_ACCOUNT_ID"; do
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
        log_err "Timed out (${attempt}×10 s) waiting for $role_arn"
        exit 1
      fi
      echo "    Not ready yet — retrying in 10 s... (attempt $attempt/30)"
      sleep 10
    done
    log_ok "Assumable: $role_arn"
  done

  mark_done wait_iam
}

# ── Step 4: Apply dev + prod in parallel ──────────────────────────────────────
run_spokes() {
  if step_done spokes; then log_skip "Step 4 — Dev + prod clusters"; return; fi
  log_step "Step 4/6 — Deploy dev and prod clusters (parallel)"

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

  mark_done spokes
  log_ok "Dev and prod clusters deployed"
}

# ── Step 5: Apply hub ─────────────────────────────────────────────────────────
run_hub() {
  if step_done hub; then log_skip "Step 5 — Hub cluster + Transit Gateway"; return; fi
  log_step "Step 5/6 — Deploy hub cluster + Transit Gateway"
  tf_apply "$ROOT_DIR/envs/hub"
  mark_done hub
  log_ok "Hub cluster deployed"
}

# ── Step 6: Update kubeconfigs ─────────────────────────────────────────────────
run_kubeconfig() {
  if step_done kubeconfig; then log_skip "Step 6 — Kubeconfig"; return; fi
  log_step "Step 6/6 — Updating kubeconfigs"
  "$SCRIPT_DIR/get-kubeconfigs.sh"
  mark_done kubeconfig
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}#######################################################${NC}"
echo -e "${CYAN}#        eks-hub-spoke  STARTUP                       #${NC}"
echo -e "${CYAN}#######################################################${NC}"

if [[ -n "$RESET" ]]; then
  rm -f "$CHECKPOINT"
  log_ok "Checkpoint cleared — starting from scratch"
fi

# Copy .example → .tfvars for any env that doesn't have one yet.
init_tfvars

# Always load values that may have been written by a previous run.
# This populates BUCKET_NAME, HUB_ACCOUNT_ID, etc. so skipped steps
# still have the variables available for subsequent steps.
load_existing_config

if [[ -f "$CHECKPOINT" ]]; then
  log_warn "Resuming from a previous run. Completed steps will be skipped."
  show_progress
fi

if [[ -z "$AUTO_APPROVE" && ! -f "$CHECKPOINT" ]]; then
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

run_prereqs
run_bootstrap
run_accounts
run_wait_iam
run_spokes
run_hub
run_kubeconfig

# Clean up checkpoint on full success
rm -f "$CHECKPOINT"

echo ""
log_ok "Startup complete — all clusters are running."
echo ""
echo "    Cluster   Account"
echo "    --------  ---------------"
echo "    eks-hub   ${HUB_ACCOUNT_ID}"
echo "    eks-dev   ${DEV_ACCOUNT_ID}"
echo "    eks-prod  ${PROD_ACCOUNT_ID}"
echo ""
echo "  kubectl config get-contexts   # list available contexts"
