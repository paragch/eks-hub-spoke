#!/usr/bin/env bash
# apply-all.sh — (Re)apply all environments in the correct order
#   with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. accounts   Apply accounts workspace (idempotent)
#   2. spokes     Apply dev + prod clusters in parallel
#   3. hub        Apply hub cluster + Transit Gateway
#   ──────────────────────────────────────────────────────────
#
#   Progress is written to .apply-all-progress in the repo root.
#   Re-running resumes from the first incomplete step.
#
#   Use startup.sh for a from-scratch deployment (includes bootstrap
#   and account ID substitution). Use this script to re-apply after
#   changes when the environment already exists.
#
# Usage:
#   ./scripts/apply-all.sh          # interactive (plan before each apply)
#   ./scripts/apply-all.sh --reset  # clear checkpoint and start fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECKPOINT="$ROOT_DIR/.apply-all-progress"

RESET=""
for arg in "$@"; do
  [[ "$arg" == "--reset" ]] && RESET="1"
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; GREY='\033[0;90m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_skip() { echo -e "${GREY}--- $* (already done — skipping)${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Checkpoint helpers ─────────────────────────────────────────────────────────
step_done() { [[ -f "$CHECKPOINT" ]] && grep -qx "$1" "$CHECKPOINT"; }
mark_done() { echo "$1" >> "$CHECKPOINT"; }

show_progress() {
  local steps=("accounts" "spokes" "hub")
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
echo -e "\n${CYAN}#######################################################${NC}"
echo -e "${CYAN}#        eks-hub-spoke  APPLY-ALL                     #${NC}"
echo -e "${CYAN}#######################################################${NC}"

if [[ -n "$RESET" ]]; then
  rm -f "$CHECKPOINT"
  log_ok "Checkpoint cleared — starting from scratch"
fi

if [[ -f "$CHECKPOINT" ]]; then
  echo ""
  echo "  Resuming from a previous run. Completed steps will be skipped."
  show_progress
fi

# ── Step 1: accounts ──────────────────────────────────────────────────────────
apply_accounts() {
  if step_done accounts; then log_skip "Step 1 — accounts"; return; fi
  log_step "Step 1/3 — Applying accounts"

  cd "$ROOT_DIR/envs/accounts"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan

  mark_done accounts
  log_ok "accounts applied"
}

# ── Step 2: dev + prod in parallel ────────────────────────────────────────────
apply_spokes() {
  if step_done spokes; then log_skip "Step 2 — Dev + prod clusters"; return; fi
  log_step "Step 2/3 — Applying dev and prod clusters (parallel)"

  local dev_log="$ROOT_DIR/.apply-dev.log"
  local prod_log="$ROOT_DIR/.apply-prod.log"
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
    log_err "Dev apply failed — see $dev_log"; tail -30 "$dev_log" >&2; exit 1
  fi
  if [[ $prod_rc -ne 0 ]]; then
    log_err "Prod apply failed — see $prod_log"; tail -30 "$prod_log" >&2; exit 1
  fi

  mark_done spokes
  log_ok "dev and prod applied"
}

# ── Step 3: hub ───────────────────────────────────────────────────────────────
apply_hub() {
  if step_done hub; then log_skip "Step 3 — Hub cluster + Transit Gateway"; return; fi
  log_step "Step 3/3 — Applying hub cluster + Transit Gateway"

  cd "$ROOT_DIR/envs/hub"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan

  mark_done hub
  log_ok "hub applied"
}

# ── Main ──────────────────────────────────────────────────────────────────────
apply_accounts
apply_spokes
apply_hub

rm -f "$CHECKPOINT"

echo ""
log_ok "All environments applied successfully!"
echo "    Run ./scripts/get-kubeconfigs.sh to refresh your kubeconfig"
