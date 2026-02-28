#!/usr/bin/env bash
# shutdown.sh — Full environment teardown with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. hub        Destroy hub cluster (TGW, EKS, ArgoCD, Karpenter)
#   2. prod-data  Destroy OpenSearch/Aurora/Neptune + db-writer + peering
#   3. spokes     Destroy dev + prod + data clusters in parallel
#   4. accounts   Remove accounts from Terraform state
#   5. bootstrap  (Optional) Destroy S3 state bucket + DynamoDB table
#   ──────────────────────────────────────────────────────────
#
#   Progress is written to .shutdown-progress in the repo root.
#   Re-running the script resumes from the first incomplete step.
#   Each step is only marked done after it fully succeeds.
#
# NOTE: AWS accounts are NOT closed by this script.
#   close_on_deletion = false is intentional — accounts are only removed
#   from Terraform state. Close them manually if needed:
#     aws organizations close-account --account-id <ID>
#
# Usage:
#   ./scripts/shutdown.sh          # interactive
#   ./scripts/shutdown.sh --reset  # clear checkpoint and start fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECKPOINT="$ROOT_DIR/.shutdown-progress"

RESET=""
for arg in "$@"; do
  [[ "$arg" == "--reset" ]] && RESET="1"
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GREY='\033[0;90m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_skip() { echo -e "${GREY}--- $* (already done — skipping)${NC}"; }
log_warn() { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Checkpoint helpers ─────────────────────────────────────────────────────────
step_done() { [[ -f "$CHECKPOINT" ]] && grep -qx "$1" "$CHECKPOINT"; }
mark_done() { echo "$1" >> "$CHECKPOINT"; }

# ── Print checkpoint status ────────────────────────────────────────────────────
show_progress() {
  local steps=("hub" "prod_data" "spokes" "accounts" "bootstrap")
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

# ── Header ────────────────────────────────────────────────────────────────────
echo -e "\n${RED}#######################################################${NC}"
echo -e "${RED}#        eks-hub-spoke  SHUTDOWN                      #${NC}"
echo -e "${RED}#######################################################${NC}"

if [[ -n "$RESET" ]]; then
  rm -f "$CHECKPOINT"
  log_ok "Checkpoint cleared — starting from scratch"
fi

if [[ -f "$CHECKPOINT" ]]; then
  log_warn "Resuming a previous shutdown run. Completed steps will be skipped."
  show_progress
fi

# ── Confirmation (only on first run, not on resume) ───────────────────────────
if [[ ! -f "$CHECKPOINT" ]]; then
  echo ""
  log_warn "This will PERMANENTLY DESTROY:"
  echo "    • All four EKS clusters (hub, dev, prod, data)"
  echo "    • prod-data databases (OpenSearch, Aurora PostgreSQL, Neptune)"
  echo "    • Transit Gateway + all VPC attachments and routes"
  echo "    • All associated VPCs, IAM roles, and node groups"
  echo "    • ArgoCD, Karpenter, and all in-cluster resources"
  echo "    • hub / dev / prod / data / prod-data Terraform state entries (accounts remain in AWS)"
  echo ""
  read -rp "Type 'destroy' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    echo "Aborted."
    exit 0
  fi
  # Create the checkpoint file now so resume skips this prompt
  touch "$CHECKPOINT"
fi

# ── Step 1: Destroy hub ───────────────────────────────────────────────────────
destroy_hub() {
  if step_done hub; then log_skip "Step 1 — Hub cluster"; return; fi
  log_step "Step 1/4 — Destroying hub cluster (TGW, EKS, ArgoCD, Karpenter)"

  cd "$ROOT_DIR/envs/hub"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done hub
  log_ok "Hub destroyed"
}

# ── Step 2: Destroy prod-data ─────────────────────────────────────────────────
# Must be destroyed before prod (peering connections reference prod VPC).
destroy_prod_data() {
  if step_done prod_data; then log_skip "Step 2 — prod-data databases + db-writer + peering"; return; fi
  log_step "Step 2/4 — Destroying prod-data (OpenSearch/Aurora/Neptune + db-writer + VPC peering)"

  cd "$ROOT_DIR/envs/prod-data"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done prod_data
  log_ok "prod-data destroyed"
}

# ── Step 3: Destroy dev + prod + data in parallel ─────────────────────────────
destroy_spokes() {
  if step_done spokes; then log_skip "Step 3 — Dev + prod + data clusters"; return; fi
  log_step "Step 3/4 — Destroying dev, prod, and data clusters (parallel)"

  local dev_log="$ROOT_DIR/.shutdown-dev.log"
  local prod_log="$ROOT_DIR/.shutdown-prod.log"
  local data_log="$ROOT_DIR/.shutdown-data.log"
  : > "$dev_log"; : > "$prod_log"; : > "$data_log"
  echo "  Logs: $dev_log  |  $prod_log  |  $data_log"

  (
    cd "$ROOT_DIR/envs/dev"
    terraform init -reconfigure >> "$dev_log" 2>&1
    terraform destroy -auto-approve >> "$dev_log" 2>&1
    echo "==> dev destroy complete" >> "$dev_log"
  ) &
  local dev_pid=$!

  (
    cd "$ROOT_DIR/envs/prod"
    terraform init -reconfigure >> "$prod_log" 2>&1
    terraform destroy -auto-approve >> "$prod_log" 2>&1
    echo "==> prod destroy complete" >> "$prod_log"
  ) &
  local prod_pid=$!

  (
    cd "$ROOT_DIR/envs/data"
    terraform init -reconfigure >> "$data_log" 2>&1
    terraform destroy -auto-approve >> "$data_log" 2>&1
    echo "==> data destroy complete" >> "$data_log"
  ) &
  local data_pid=$!

  echo "  Waiting for dev (PID $dev_pid), prod (PID $prod_pid), and data (PID $data_pid)..."
  local dev_rc=0 prod_rc=0 data_rc=0
  wait "$dev_pid"  || dev_rc=$?
  wait "$prod_pid" || prod_rc=$?
  wait "$data_pid" || data_rc=$?

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
  if [[ $data_rc -ne 0 ]]; then
    log_err "Data destroy failed — see $data_log"
    tail -30 "$data_log" >&2
    exit 1
  fi

  mark_done spokes
  log_ok "Dev, prod, and data clusters destroyed"
}

# ── Step 4: Remove accounts from state ────────────────────────────────────────
destroy_accounts() {
  if step_done accounts; then log_skip "Step 4 — Accounts state"; return; fi
  log_step "Step 4/4 — Removing accounts from Terraform state"

  cd "$ROOT_DIR/envs/accounts"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done accounts
  log_ok "Accounts removed from state"

  echo ""
  log_warn "The hub / dev / prod AWS accounts still exist in AWS Organizations."
  echo "  To close them permanently:"
  echo "    aws organizations close-account --account-id <ACCOUNT_ID>"
}

# ── Optional step 4: Destroy state backend ────────────────────────────────────
destroy_bootstrap() {
  if step_done bootstrap; then log_skip "Step 4 — State backend (bootstrap)"; return; fi

  echo ""
  read -rp "Also destroy the S3 state backend and DynamoDB table? [y/N] " yn
  if [[ "${yn,,}" != "y" ]]; then
    log_ok "State backend preserved"
    echo "    To remove it later: cd bootstrap && terraform destroy"
    # Mark done so re-runs don't prompt again
    mark_done bootstrap
    return
  fi

  log_warn "Destroying the state backend makes Terraform state unrecoverable."
  read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM2
  if [[ "$CONFIRM2" != "yes" ]]; then
    log_ok "Skipping state backend destruction"
    mark_done bootstrap
    return
  fi

  log_step "Step 4 — Destroying state backend (S3 + DynamoDB)"
  cd "$ROOT_DIR/bootstrap"
  terraform init

  BUCKET=$(terraform output -raw state_bucket_name 2>/dev/null || true)
  if [[ -n "$BUCKET" ]]; then
    log_ok "Emptying bucket: $BUCKET"
    aws s3 rm "s3://$BUCKET" --recursive

    # Remove all versions and delete markers so the versioned bucket can be deleted
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

  mark_done bootstrap
  log_ok "State backend destroyed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
destroy_hub
destroy_prod_data
destroy_spokes
destroy_accounts
destroy_bootstrap

# Clean up checkpoint on full success
rm -f "$CHECKPOINT"

echo ""
log_ok "Shutdown complete."
