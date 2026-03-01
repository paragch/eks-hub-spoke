#!/usr/bin/env bash
# teardown.sh — Destroy all cluster environments and accounts state
#   with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. hub        Destroy hub cluster (TGW, EKS, ArgoCD, Karpenter)
#   2. prod-data  Destroy OpenSearch/Aurora/Neptune + db-writer + peering
#   3. prod       Destroy prod cluster
#   4. accounts   Remove accounts from Terraform state
#   ──────────────────────────────────────────────────────────
#
#   Progress is written to .teardown-progress in the repo root.
#   Re-running resumes from the first incomplete step.
#   The 'yes' confirmation is only shown on the first run.
#
#   For a full teardown including the S3 state backend use shutdown.sh.
#
# Usage:
#   ./scripts/teardown.sh          # interactive
#   ./scripts/teardown.sh --reset  # clear checkpoint and start fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECKPOINT="$ROOT_DIR/.teardown-progress"

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

show_progress() {
  local steps=("hub" "prod_data" "prod" "accounts")
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
echo -e "${RED}#        eks-hub-spoke  TEARDOWN                      #${NC}"
echo -e "${RED}#######################################################${NC}"

if [[ -n "$RESET" ]]; then
  rm -f "$CHECKPOINT"
  log_ok "Checkpoint cleared — starting from scratch"
fi

if [[ -f "$CHECKPOINT" ]]; then
  log_warn "Resuming a previous teardown run. Completed steps will be skipped."
  show_progress
fi

# ── Confirmation (only on first run) ──────────────────────────────────────────
if [[ ! -f "$CHECKPOINT" ]]; then
  echo ""
  log_warn "This will DESTROY both EKS clusters and associated resources."
  log_warn "This includes the prod-data databases (OpenSearch, Aurora, Neptune)."
  log_warn "AWS accounts will remain in Organizations (use shutdown.sh or close"
  log_warn "them manually if you want to remove them entirely)."
  echo ""
  read -rp "Type 'yes' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
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

# ── Step 3: Destroy prod ──────────────────────────────────────────────────────
destroy_prod() {
  if step_done prod; then log_skip "Step 3 — Prod cluster"; return; fi
  log_step "Step 3/4 — Destroying prod cluster"

  cd "$ROOT_DIR/envs/prod"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done prod
  log_ok "Prod cluster destroyed"
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
}

# ── Main ──────────────────────────────────────────────────────────────────────
destroy_hub
destroy_prod_data
destroy_prod
destroy_accounts

rm -f "$CHECKPOINT"

echo ""
log_ok "All environments destroyed."
log_warn "The hub / prod AWS accounts still exist in AWS Organizations."
echo "    Close them manually or run ./scripts/shutdown.sh for a full teardown."
echo "    The S3 state bucket and DynamoDB lock table were NOT destroyed."
echo "    To remove them: cd bootstrap && terraform destroy"
