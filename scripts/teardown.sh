#!/usr/bin/env bash
# teardown.sh — Destroy all cluster environments and accounts state
#   with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. hub        Destroy hub cluster (TGW, EKS, ArgoCD, Karpenter)
#   2. spokes     Destroy dev + prod clusters in parallel
#   3. accounts   Remove accounts from Terraform state
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
  local steps=("hub" "spokes" "accounts")
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
  log_warn "This will DESTROY all three EKS clusters and associated resources."
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
  log_step "Step 1/3 — Destroying hub cluster (TGW, EKS, ArgoCD, Karpenter)"

  cd "$ROOT_DIR/envs/hub"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done hub
  log_ok "Hub destroyed"
}

# ── Step 2: Destroy dev + prod in parallel ────────────────────────────────────
destroy_spokes() {
  if step_done spokes; then log_skip "Step 2 — Dev + prod clusters"; return; fi
  log_step "Step 2/3 — Destroying dev and prod clusters (parallel)"

  local dev_log="$ROOT_DIR/.teardown-dev.log"
  local prod_log="$ROOT_DIR/.teardown-prod.log"
  : > "$dev_log"; : > "$prod_log"
  echo "  Logs: $dev_log  |  $prod_log"

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

  echo "  Waiting for dev (PID $dev_pid) and prod (PID $prod_pid)..."
  local dev_rc=0 prod_rc=0
  wait "$dev_pid"  || dev_rc=$?
  wait "$prod_pid" || prod_rc=$?

  if [[ $dev_rc -ne 0 ]]; then
    log_err "Dev destroy failed — see $dev_log"; tail -30 "$dev_log" >&2; exit 1
  fi
  if [[ $prod_rc -ne 0 ]]; then
    log_err "Prod destroy failed — see $prod_log"; tail -30 "$prod_log" >&2; exit 1
  fi

  mark_done spokes
  log_ok "Dev and prod clusters destroyed"
}

# ── Step 3: Remove accounts from state ───────────────────────────────────────
destroy_accounts() {
  if step_done accounts; then log_skip "Step 3 — Accounts state"; return; fi
  log_step "Step 3/3 — Removing accounts from Terraform state"

  cd "$ROOT_DIR/envs/accounts"
  terraform init -reconfigure
  terraform destroy -auto-approve

  mark_done accounts
  log_ok "Accounts removed from state"
}

# ── Main ──────────────────────────────────────────────────────────────────────
destroy_hub
destroy_spokes
destroy_accounts

rm -f "$CHECKPOINT"

echo ""
log_ok "All environments destroyed."
log_warn "The hub / dev / prod AWS accounts still exist in AWS Organizations."
echo "    Close them manually or run ./scripts/shutdown.sh for a full teardown."
echo "    The S3 state bucket and DynamoDB lock table were NOT destroyed."
echo "    To remove them: cd bootstrap && terraform destroy"
