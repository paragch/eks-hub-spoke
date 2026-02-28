#!/usr/bin/env bash
# teardown.sh — Destroy all cluster environments and accounts state.
#   hub → dev + prod (parallel) → accounts
#
# For a full teardown including the S3 state backend use shutdown.sh.
#
# Usage: ./scripts/teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}=======================================================${NC}\n${CYAN}  $*${NC}\n${CYAN}=======================================================${NC}"; }
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_warn() { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

echo ""
log_warn "This will DESTROY all three EKS clusters and associated resources."
log_warn "The AWS accounts will remain in Organizations (use shutdown.sh or"
log_warn "close them manually if you want to remove them entirely)."
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

destroy_env() {
  local env="$1"
  local dir="$ROOT_DIR/envs/$env"

  log_step "Destroying: $env"
  cd "$dir"
  terraform init -reconfigure
  terraform destroy -auto-approve
  log_ok "$env destroyed"
}

# Hub first — owns the TGW and references dev + prod state
destroy_env hub

# Dev + prod in parallel
log_step "Destroying dev and prod clusters (parallel)"

dev_log="$ROOT_DIR/.teardown-dev.log"
prod_log="$ROOT_DIR/.teardown-prod.log"
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

dev_rc=0; prod_rc=0
wait "$dev_pid"  || dev_rc=$?
wait "$prod_pid" || prod_rc=$?

if [[ $dev_rc -ne 0 ]]; then
  log_err "Dev destroy failed — see $dev_log"; tail -30 "$dev_log" >&2; exit 1
fi
if [[ $prod_rc -ne 0 ]]; then
  log_err "Prod destroy failed — see $prod_log"; tail -30 "$prod_log" >&2; exit 1
fi
log_ok "dev and prod clusters destroyed"

# Remove accounts from state (accounts remain in AWS Organizations)
destroy_env accounts

echo ""
log_ok "All environments destroyed."
log_warn "The hub / dev / prod AWS accounts still exist in AWS Organizations."
echo "    Close them manually or run ./scripts/shutdown.sh for a full teardown."
echo "    The S3 state bucket and DynamoDB lock table were NOT destroyed."
echo "    To remove them: cd bootstrap && terraform destroy"
