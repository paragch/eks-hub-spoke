#!/usr/bin/env bash
# run-pipeline.sh — Submit the HR Events Spark batch job to EMR on EKS.
#
#   What it does
#   ────────────────────────────────────────────────────────────────────────
#   1. Validates prerequisites (aws, jq, curl)
#   2. Downloads aws-msk-iam-auth-2.2.0-all.jar from Maven Central (if needed)
#   3. Uploads the JAR, seed data JSONL, and PySpark script to S3
#   4. Reads the EMR virtual cluster ID, job execution role ARN, S3 bucket
#      name, and MSK bootstrap servers from `terraform output` in envs/prod
#   5. Submits the EMR on EKS job run
#   6. Polls describe-job-run until the job reaches COMPLETED or FAILED
#   7. Prints the CloudWatch log group for debugging
#
#   Usage
#   ────────────────────────────────────────────────────────────────────────
#   ./scripts/run-pipeline.sh                # interactive
#   ./scripts/run-pipeline.sh --auto-approve # skip confirmation prompt
#
#   Prerequisites
#   ────────────────────────────────────────────────────────────────────────
#   • AWS CLI configured for the prod account
#   • Terraform state for envs/prod must be up to date (run `terraform apply`)
#   • The kafka-mq-bridge deployment must be running (to consume from Kafka)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}==> $*${NC}"; }
log_info() { echo -e "${CYAN}--- $*${NC}"; }
log_warn() { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
log_err()  { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# ── Parse flags ───────────────────────────────────────────────────────────────
AUTO_APPROVE=""
for arg in "$@"; do
  [[ "$arg" == "--auto-approve" ]] && AUTO_APPROVE="1"
done

# ── Constants ─────────────────────────────────────────────────────────────────
JAR_VERSION="2.2.0"
JAR_NAME="aws-msk-iam-auth-${JAR_VERSION}-all.jar"
JAR_URL="https://repo1.maven.org/maven2/software/amazon/msk/aws-msk-iam-auth/${JAR_VERSION}/${JAR_NAME}"
JAR_LOCAL="/tmp/${JAR_NAME}"
EMR_RELEASE_LABEL="emr-6.15.0-latest"
POLL_INTERVAL_SECS=30
POLL_MAX_ATTEMPTS=60   # 30 min timeout

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
log_info "Checking prerequisites"
for cmd in aws jq curl terraform; do
  if ! command -v "$cmd" &>/dev/null; then
    log_err "$cmd is not installed or not in PATH"
    exit 1
  fi
done

if ! aws sts get-caller-identity &>/dev/null; then
  log_err "AWS credentials not configured"
  exit 1
fi
log_ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# ── Step 2: Download the MSK IAM auth JAR ─────────────────────────────────────
if [[ -f "$JAR_LOCAL" ]]; then
  log_info "MSK IAM auth JAR already downloaded: $JAR_LOCAL"
else
  log_info "Downloading $JAR_NAME from Maven Central..."
  curl -fSL --progress-bar -o "$JAR_LOCAL" "$JAR_URL"
  log_ok "Downloaded: $JAR_LOCAL"
fi

# ── Step 3: Read prod Terraform outputs ───────────────────────────────────────
log_info "Reading Terraform outputs from envs/prod"
cd "$ROOT_DIR/envs/prod"
terraform init -reconfigure -input=false > /dev/null 2>&1 || true

VIRTUAL_CLUSTER_ID=$(terraform output -raw emr_virtual_cluster_id 2>/dev/null)
JOB_ROLE_ARN=$(terraform output -raw emr_job_execution_role_arn 2>/dev/null)
BUCKET=$(terraform output -raw emr_landing_zone_bucket_name 2>/dev/null)
BOOTSTRAP_SERVERS=$(terraform output -raw msk_bootstrap_brokers_iam 2>/dev/null)

if [[ -z "$VIRTUAL_CLUSTER_ID" || -z "$JOB_ROLE_ARN" || -z "$BUCKET" || -z "$BOOTSTRAP_SERVERS" ]]; then
  log_err "One or more Terraform outputs are empty. Run 'terraform apply' in envs/prod first."
  log_err "  emr_virtual_cluster_id     = '${VIRTUAL_CLUSTER_ID:-}'"
  log_err "  emr_job_execution_role_arn = '${JOB_ROLE_ARN:-}'"
  log_err "  emr_landing_zone_bucket    = '${BUCKET:-}'"
  log_err "  msk_bootstrap_brokers_iam  = '${BOOTSTRAP_SERVERS:-}'"
  exit 1
fi

log_ok "Virtual cluster ID : $VIRTUAL_CLUSTER_ID"
log_ok "Job execution role : $JOB_ROLE_ARN"
log_ok "S3 landing zone    : $BUCKET"
log_ok "MSK brokers        : $BOOTSTRAP_SERVERS"
cd "$ROOT_DIR"

# ── Step 4: Upload artifacts to S3 ───────────────────────────────────────────
log_info "Uploading artifacts to s3://$BUCKET"

aws s3 cp "$JAR_LOCAL" "s3://${BUCKET}/jars/${JAR_NAME}" \
  --no-progress
log_ok "Uploaded JAR → s3://${BUCKET}/jars/${JAR_NAME}"

aws s3 cp "$ROOT_DIR/pipeline/seed-data/hr_employees.jsonl" \
  "s3://${BUCKET}/seed-data/hr_employees.jsonl" \
  --no-progress
log_ok "Uploaded seed data → s3://${BUCKET}/seed-data/hr_employees.jsonl"

aws s3 cp "$ROOT_DIR/pipeline/spark-jobs/hr_events_producer.py" \
  "s3://${BUCKET}/spark-jobs/hr_events_producer.py" \
  --no-progress
log_ok "Uploaded Spark job → s3://${BUCKET}/spark-jobs/hr_events_producer.py"

# ── Step 5: Confirm and submit ────────────────────────────────────────────────
S3_INPUT="s3://${BUCKET}/seed-data/hr_employees.jsonl"
S3_SCRIPT="s3://${BUCKET}/spark-jobs/hr_events_producer.py"
S3_JAR="s3://${BUCKET}/jars/${JAR_NAME}"
LOG_GROUP="/emr-on-eks/hr-events-producer"

echo ""
echo "  Job to submit:"
echo "    Release label : $EMR_RELEASE_LABEL"
echo "    Script        : $S3_SCRIPT"
echo "    Input         : $S3_INPUT"
echo "    JAR           : $S3_JAR"
echo "    Log group     : $LOG_GROUP"
echo ""

if [[ -z "$AUTO_APPROVE" ]]; then
  read -rp "Submit EMR job? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

# ── Step 6: Submit EMR on EKS job run ────────────────────────────────────────
log_info "Submitting EMR on EKS job run"

JOB_RUN_ID=$(aws emr-containers start-job-run \
  --virtual-cluster-id "$VIRTUAL_CLUSTER_ID" \
  --name "hr-events-producer-$(date +%Y%m%d%H%M%S)" \
  --execution-role-arn "$JOB_ROLE_ARN" \
  --release-label "$EMR_RELEASE_LABEL" \
  --job-driver "$(cat <<EOF
{
  "sparkSubmitJobDriver": {
    "entryPoint": "${S3_SCRIPT}",
    "sparkSubmitParameters": "--conf spark.jars=${S3_JAR} --conf spark.kafka.bootstrap.servers=${BOOTSTRAP_SERVERS} --conf spark.hr.input.path=${S3_INPUT}"
  }
}
EOF
)" \
  --configuration-overrides "$(cat <<EOF
{
  "monitoringConfiguration": {
    "cloudWatchMonitoringConfiguration": {
      "logGroupName": "${LOG_GROUP}",
      "logStreamNamePrefix": "hr-events-producer"
    },
    "s3MonitoringConfiguration": {
      "logUri": "s3://${BUCKET}/logs/hr-events-producer/"
    }
  }
}
EOF
)" \
  --query 'id' --output text)

log_ok "Job submitted — run ID: $JOB_RUN_ID"
echo ""

# ── Step 7: Poll for completion ───────────────────────────────────────────────
log_info "Polling job status (every ${POLL_INTERVAL_SECS}s, timeout: $((POLL_INTERVAL_SECS * POLL_MAX_ATTEMPTS / 60)) min)"

attempt=0
while true; do
  STATUS=$(aws emr-containers describe-job-run \
    --virtual-cluster-id "$VIRTUAL_CLUSTER_ID" \
    --id "$JOB_RUN_ID" \
    --query 'jobRun.state' --output text)

  echo "  [$(date '+%H:%M:%S')] Status: $STATUS"

  case "$STATUS" in
    COMPLETED)
      echo ""
      log_ok "Job COMPLETED successfully"
      break
      ;;
    FAILED|CANCELLED|CANCEL_PENDING)
      echo ""
      log_err "Job $STATUS — check CloudWatch logs for details"
      echo ""
      echo "  CloudWatch log group : $LOG_GROUP"
      echo "  S3 logs              : s3://${BUCKET}/logs/hr-events-producer/"
      echo ""
      echo "  To view logs:"
      echo "    aws logs tail $LOG_GROUP --follow"
      exit 1
      ;;
  esac

  attempt=$((attempt + 1))
  if [[ $attempt -ge $POLL_MAX_ATTEMPTS ]]; then
    log_err "Timed out waiting for job completion after $((POLL_INTERVAL_SECS * POLL_MAX_ATTEMPTS / 60)) minutes"
    exit 1
  fi

  sleep "$POLL_INTERVAL_SECS"
done

echo ""
echo "  CloudWatch log group : $LOG_GROUP"
echo "  S3 logs              : s3://${BUCKET}/logs/hr-events-producer/"
echo ""
echo "  To view logs:"
echo "    aws logs tail $LOG_GROUP --follow"
echo ""
log_ok "Pipeline run complete. Kafka-MQ bridge should now be forwarding events to Amazon MQ."
echo "  Next: verify the db-writer pod has written records to OpenSearch/Aurora/Neptune."
