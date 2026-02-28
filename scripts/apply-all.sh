#!/usr/bin/env bash
# apply-all.sh — (Re)apply all environments in the correct order.
#   accounts → dev + prod (parallel) → hub
#
# Use this script after initial bootstrap and account IDs have already been
# substituted in the tfvars files. For a from-scratch deployment use startup.sh.
#
# Usage: ./scripts/apply-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Colour helpers ─────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

apply_env() {
  local env="$1"
  local dir="$ROOT_DIR/envs/$env"

  log_step "Applying: $env"
  cd "$dir"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan
  log_ok "$env applied"
}

# accounts first (idempotent — safe to re-run)
apply_env accounts

# dev + prod in parallel
log_step "Applying dev and prod clusters (parallel)"

dev_log="$ROOT_DIR/.apply-dev.log"
prod_log="$ROOT_DIR/.apply-prod.log"
: > "$dev_log"; : > "$prod_log"
echo "  Logs: $dev_log  |  $prod_log"

(
  cd "$ROOT_DIR/envs/dev"
  terraform init -reconfigure >> "$dev_log" 2>&1
  terraform apply -auto-approve >> "$dev_log" 2>&1
) &
dev_pid=$!

(
  cd "$ROOT_DIR/envs/prod"
  terraform init -reconfigure >> "$prod_log" 2>&1
  terraform apply -auto-approve >> "$prod_log" 2>&1
) &
prod_pid=$!

dev_rc=0; prod_rc=0
wait "$dev_pid"  || dev_rc=$?
wait "$prod_pid" || prod_rc=$?

if [[ $dev_rc -ne 0 ]]; then
  log_err "Dev apply failed — see $dev_log"; tail -30 "$dev_log" >&2; exit 1
fi
if [[ $prod_rc -ne 0 ]]; then
  log_err "Prod apply failed — see $prod_log"; tail -30 "$prod_log" >&2; exit 1
fi
log_ok "dev and prod applied"

# hub last (reads dev + prod remote state and owns the TGW)
apply_env hub

echo ""
log_ok "All environments applied successfully!"
echo "    Run ./scripts/get-kubeconfigs.sh to refresh your kubeconfig"
