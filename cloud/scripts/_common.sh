#!/usr/bin/env bash
# Shared helpers for cloud/scripts. Source from other scripts; do not execute directly.
set -euo pipefail

_CLOUD_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd "$_CLOUD_SCRIPTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CLOUD_DIR/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REPO_PATH="${REPO_PATH:-/opt/swe-bench}"
MINI_SWE_RUNS_PATH="${MINI_SWE_RUNS_PATH:-$REPO_PATH/mini-swe-runs}"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

cloud_stage_usage() {
  local cmd="${1:-$0}"
  echo "usage: $cmd <stage> ..." >&2
  echo "  stage: SST stack name (e.g. qwen, kimi)" >&2
}

# Validate first positional arg as stage; sets and exports STAGE.
cloud_parse_stage() {
  local cmd="$1"
  shift
  if [[ $# -lt 1 || "$1" == -* ]]; then
    cloud_stage_usage "$cmd"
    exit 1
  fi
  STAGE="$1"
  if [[ ! "$STAGE" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
    echo "error: invalid stage name: $STAGE" >&2
    exit 1
  fi
  export STAGE
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
    echo "error: no EC2 instance with tag Name=$name (deploy with ./scripts/deploy.sh <stage>?)" >&2
    exit 1
  fi
  echo "$id"
}

ssh_proxy_cmd() {
  local instance_id="$1"
  printf 'aws ssm start-session --target %s --document-name AWS-StartSSHSession --parameters portNumber=%%p' "$instance_id"
}

# SSH/scp/rsync over SSM (no inbound port 22).
ssh_cmd() {
  local instance_id
  instance_id="$(get_instance_id)"
  ssh -i /dev/null \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o "ProxyCommand=$(ssh_proxy_cmd "$instance_id")" \
    "${REMOTE_USER}@${instance_id}" "$@"
}

scp_to_remote() {
  local local_path="$1"
  local remote_path="$2"
  local instance_id
  instance_id="$(get_instance_id)"
  scp -i /dev/null \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o "ProxyCommand=$(ssh_proxy_cmd "$instance_id")" \
    "$local_path" "${REMOTE_USER}@${instance_id}:${remote_path}"
}

rsync_to_remote() {
  local instance_id
  instance_id="$(get_instance_id)"
  rsync -az --delete \
    -e "ssh -i /dev/null -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand='$(ssh_proxy_cmd "$instance_id")'" \
    "$@"
}

rsync_from_remote() {
  local instance_id
  instance_id="$(get_instance_id)"
  rsync -az \
    -e "ssh -i /dev/null -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand='$(ssh_proxy_cmd "$instance_id")'" \
    "$@"
}

remote_exec() {
  ssh_cmd "$@"
}

remote_bash() {
  local script="$1"
  shift
  ssh_cmd "bash -s" "$@" <<EOF
$script
EOF
}

wait_for_ssm() {
  local instance_id="$1"
  local i
  for i in $(seq 1 60); do
    if aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null | grep -q Online; then
      return 0
    fi
    sleep 5
  done
  echo "warn: instance not reporting Online in SSM yet" >&2
}
