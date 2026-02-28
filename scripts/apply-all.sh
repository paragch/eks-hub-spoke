#!/usr/bin/env bash
# apply-all.sh — (Re)apply all environments in the correct order
#   with checkpoint/resume support.
#
#   Steps
#   ──────────────────────────────────────────────────────────
#   1. accounts   Apply accounts workspace (idempotent)
#   2. spokes     Apply dev + prod + data clusters in parallel
#   3. hub        Apply hub cluster + Transit Gateway
#   4. prod-data  Apply prod-data databases + db-writer microservice
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
  local steps=("accounts" "spokes" "hub" "prod_data")
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
  log_step "Step 1/4 — Applying accounts"

  cd "$ROOT_DIR/envs/accounts"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan

  mark_done accounts
  log_ok "accounts applied"
}

# ── Step 2: dev + prod + data in parallel ─────────────────────────────────────
apply_spokes() {
  if step_done spokes; then log_skip "Step 2 — Dev + prod + data clusters"; return; fi
  log_step "Step 2/4 — Applying dev, prod, and data clusters (parallel)"

  local dev_log="$ROOT_DIR/.apply-dev.log"
  local prod_log="$ROOT_DIR/.apply-prod.log"
  local data_log="$ROOT_DIR/.apply-data.log"
  : > "$dev_log"; : > "$prod_log"; : > "$data_log"
  echo "  Logs: $dev_log  |  $prod_log  |  $data_log"

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

  (
    cd "$ROOT_DIR/envs/data"
    terraform init -reconfigure >> "$data_log" 2>&1
    terraform apply -auto-approve >> "$data_log" 2>&1
    echo "==> data apply complete" >> "$data_log"
  ) &
  local data_pid=$!

  echo "  Waiting for dev (PID $dev_pid), prod (PID $prod_pid), and data (PID $data_pid)..."
  local dev_rc=0 prod_rc=0 data_rc=0
  wait "$dev_pid"  || dev_rc=$?
  wait "$prod_pid" || prod_rc=$?
  wait "$data_pid" || data_rc=$?

  if [[ $dev_rc -ne 0 ]]; then
    log_err "Dev apply failed — see $dev_log"; tail -30 "$dev_log" >&2; exit 1
  fi
  if [[ $prod_rc -ne 0 ]]; then
    log_err "Prod apply failed — see $prod_log"; tail -30 "$prod_log" >&2; exit 1
  fi
  if [[ $data_rc -ne 0 ]]; then
    log_err "Data apply failed — see $data_log"; tail -30 "$data_log" >&2; exit 1
  fi

  mark_done spokes
  log_ok "dev, prod, and data applied"
}

# ── Step 3: hub ───────────────────────────────────────────────────────────────
apply_hub() {
  if step_done hub; then log_skip "Step 3 — Hub cluster + Transit Gateway"; return; fi
  log_step "Step 3/4 — Applying hub cluster + Transit Gateway"

  cd "$ROOT_DIR/envs/hub"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan

  mark_done hub
  log_ok "hub applied"
}

# ── Portable sed -i ────────────────────────────────────────────────────────────
sed_inplace() {
  local pattern="$1"; shift
  if sed --version 2>&1 | grep -q GNU 2>/dev/null; then
    sed -i "$pattern" "$@"
  else
    sed -i '' "$pattern" "$@"
  fi
}

# ── Step 4: prod-data ─────────────────────────────────────────────────────────
apply_prod_data() {
  if step_done prod_data; then log_skip "Step 4 — prod-data (OpenSearch/Aurora/Neptune + db-writer)"; return; fi
  log_step "Step 4/4 — Applying prod-data databases + db-writer microservice"

  # Populate eks-prod cluster details into prod-data tfvars if still placeholder
  local prod_tfvars="$ROOT_DIR/envs/prod-data/terraform.tfvars"
  if grep -q 'REPLACE_WITH_PROD_CLUSTER_ENDPOINT' "$prod_tfvars" 2>/dev/null; then
    cd "$ROOT_DIR/envs/prod"
    terraform init -reconfigure -input=false > /dev/null 2>&1 || true
    local prod_endpoint prod_ca
    prod_endpoint=$(terraform output -raw cluster_endpoint 2>/dev/null || true)
    prod_ca=$(terraform output -raw cluster_certificate_authority_data 2>/dev/null || true)
    [[ -n "$prod_endpoint" ]] && sed_inplace "s|REPLACE_WITH_PROD_CLUSTER_ENDPOINT|${prod_endpoint}|g" "$prod_tfvars"
    [[ -n "$prod_ca"       ]] && sed_inplace "s|REPLACE_WITH_PROD_CLUSTER_CA_DATA|${prod_ca}|g"       "$prod_tfvars"
  fi

  cd "$ROOT_DIR/envs/prod-data"
  terraform init -reconfigure
  terraform plan -out=tfplan
  terraform apply tfplan
  rm -f tfplan

  mark_done prod_data
  log_ok "prod-data applied"
}

# ── Main ──────────────────────────────────────────────────────────────────────
apply_accounts
apply_spokes
apply_hub
apply_prod_data

rm -f "$CHECKPOINT"

echo ""
log_ok "All environments applied successfully!"
echo "    Run ./scripts/get-kubeconfigs.sh to refresh your kubeconfig"
