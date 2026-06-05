#!/usr/bin/env bash
# Core helpers for the swb CLI: paths, stage parsing, AWS checks, instance
# lookup, waits. Source only; do not execute directly.
set -euo pipefail

# Several of these are consumed by the sourcing script (swb), not here.
# shellcheck disable=SC2034
_CLOUD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd "$_CLOUD_LIB_DIR/.." && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$CLOUD_DIR/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REPO_PATH="${REPO_PATH:-/opt/swe-bench}"
MINI_SWE_RUNS_PATH="${MINI_SWE_RUNS_PATH:-$REPO_PATH/mini-swe-runs}"
REMOTE_GIT_DIR="${REMOTE_GIT_DIR:-/data/repo.git}"
# shellcheck disable=SC2034
SNAPSHOT_ID_FILE="$CLOUD_DIR/.snapshot-id"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

# Validate stage name; sets and exports STAGE.
cloud_parse_stage() {
  local stage="${1:-}"
  if [[ -z "$stage" || "$stage" == -* ]]; then
    echo "error: missing <stage> (SST stack name, e.g. qwen, kimi)" >&2
    exit 1
  fi
  if [[ ! "$stage" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
    echo "error: invalid stage name: $stage" >&2
    exit 1
  fi
  STAGE="$stage"
  export STAGE
}

# Validate RUN_NAME (bare name only, no paths); sets and exports RUN_NAME.
cloud_parse_run_name() {
  local raw="${1:-verified-full-v2}"
  if [[ -z "$raw" || "$raw" == */* ]]; then
    echo "error: pass RUN_NAME only (e.g. smoke-qwen), not a path" >&2
    exit 1
  fi
  RUN_NAME="$raw"
  export RUN_NAME
}

cloud_print_context() {
  local account
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)"
  echo "stage=$STAGE region=$AWS_REGION account=$account"
}

require_aws() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "error: aws CLI not found" >&2
    exit 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "error: AWS credentials not active (run: aws sso login)" >&2
    exit 1
  fi
}

require_ssm_plugin() {
  if command -v session-manager-plugin >/dev/null 2>&1; then
    return 0
  fi
  echo "error: AWS Session Manager plugin not found (required for ssh over SSM)" >&2
  echo "  macOS: brew install session-manager-plugin" >&2
  echo "  docs:  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
}

get_instance_id() {
  if [[ -n "${RUNNER_INSTANCE_ID:-}" ]]; then
    echo "$RUNNER_INSTANCE_ID"
    return
  fi
  local name="swe-bench-runner-${STAGE}"
  local id
  id="$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=$name" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$id" || "$id" == "None" ]]; then
    echo "error: no EC2 instance with tag Name=$name (deploy with: swb deploy $STAGE)" >&2
    exit 1
  fi
  echo "$id"
}

get_data_volume_id() {
  local id
  id="$(aws ec2 describe-volumes \
    --filters "Name=tag:Name,Values=swe-bench-runner-${STAGE}-data" \
    --query 'Volumes[0].VolumeId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$id" || "$id" == "None" ]]; then
    echo "error: no data volume tagged swe-bench-runner-${STAGE}-data" >&2
    exit 1
  fi
  echo "$id"
}

runner_stack_exists() {
  local n
  n="$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=swe-bench-runner-${STAGE}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'length(Reservations[0].Instances)' \
    --output text 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[1-9] ]]
}

cloud_confirm_destroy() {
  local destroy_phrase="destroy $STAGE"
  echo
  echo "======================================================================"
  echo "PERMANENT DESTROY — stage '$STAGE' ($(cloud_print_context))"
  echo "======================================================================"
  echo
  echo "This runs 'sst remove' and deletes ALL resources for this stage:"
  echo "  - EC2 instance swe-bench-runner-$STAGE"
  echo "  - Data EBS volume swe-bench-runner-$STAGE-data (default ~500 GiB gp3)"
  echo "    Docker images and ALL benchmark results"
  echo "  - IAM role, security group, volume attachment"
  echo
  echo "Alternatives (keep data or export first):"
  echo "  Pause compute, keep volume:  swb stop $STAGE"
  echo "  Copy results to laptop:      swb results pull $STAGE <RUN_NAME>"
  echo "  Archive zip to R2:           swb results push $STAGE <RUN_NAME>"
  echo "  Restore from R2:             swb results restore $STAGE <RUN_NAME>"
  echo
  read -r -p "Continue with permanent destroy? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
  echo
  read -r -p "Type '$destroy_phrase' to confirm: " confirm
  if [[ "$confirm" != "$destroy_phrase" ]]; then
    echo "Aborted (expected exactly: $destroy_phrase)."
    exit 0
  fi
  echo
  read -r -p "Type '$STAGE' again to confirm: " confirm2
  if [[ "$confirm2" != "$STAGE" ]]; then
    echo "Aborted (confirmation did not match stage name)."
    exit 0
  fi
}

wait_for_ssm() {
  local instance_id="$1"
  local _i
  for _i in $(seq 1 60); do
    if aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null | grep -q Online; then
      return 0
    fi
    sleep 5
  done
  echo "error: instance $instance_id not Online in SSM after 5m" >&2
  return 1
}

wait_ssm_command() {
  local cmd_id="$1"
  local instance_id="$2"
  local _i status
  for _i in $(seq 1 120); do
    status="$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query Status \
      --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        echo "error: SSM command $cmd_id failed ($status)" >&2
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query '[StandardOutputContent,StandardErrorContent]' \
          --output text 2>/dev/null | tail -40 >&2 || true
        return 1
        ;;
    esac
    sleep 5
  done
  echo "error: SSM command $cmd_id timed out waiting for completion" >&2
  return 1
}
