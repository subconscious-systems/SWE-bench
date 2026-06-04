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
CLOUD_KNOWN_HOSTS="$CLOUD_DIR/.runner-known-hosts"
UV_BIN="/usr/local/bin/uv"
touch "$CLOUD_KNOWN_HOSTS" 2>/dev/null || true
chmod 600 "$CLOUD_KNOWN_HOSTS" 2>/dev/null || true

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

require_ssm_plugin() {
  if command -v session-manager-plugin >/dev/null 2>&1; then
    return 0
  fi
  echo "error: AWS Session Manager plugin not found (required for ssh/scp over SSM)" >&2
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
    echo "error: no EC2 instance with tag Name=$name (deploy with ./scripts/deploy.sh <stage>?)" >&2
    exit 1
  fi
  echo "$id"
}

# Data EBS volume for this stage (one per SST stack). May exist after stack destroy.
get_data_volume_id() {
  local name="swe-bench-runner-${STAGE}-data"
  local id
  id="$(aws ec2 describe-volumes \
    --filters "Name=tag:Name,Values=$name" \
    --query 'Volumes[?State!=`deleted`] | [0].VolumeId' \
    --output text 2>/dev/null || true)"
  if [[ -n "$id" && "$id" != "None" ]]; then
    echo "$id"
    return 0
  fi
  local instance_id
  instance_id="$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=swe-bench-runner-${STAGE}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
    return 1
  fi
  id="$(aws ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=$instance_id" \
    --query 'Volumes[?Attachments[0].Device==`/dev/sdf` || Attachments[0].Device==`/dev/xvdf` || Attachments[0].Device==`/dev/nvme1n1`] | [0].VolumeId' \
    --output text 2>/dev/null || true)"
  if [[ -n "$id" && "$id" != "None" ]]; then
    echo "$id"
    return 0
  fi
  return 1
}

delete_data_volume() {
  local vol_id="$1"
  local i state
  for i in $(seq 1 60); do
    state="$(aws ec2 describe-volumes \
      --volume-ids "$vol_id" \
      --query 'Volumes[0].State' \
      --output text 2>/dev/null || echo deleted)"
    case "$state" in
      deleted|None|"") echo "Data volume $vol_id deleted."; return 0 ;;
      available)
        aws ec2 delete-volume --volume-id "$vol_id"
        echo "Deleted data volume $vol_id"
        return 0
        ;;
      in-use) sleep 5 ;;
    esac
    sleep 5
  done
  echo "error: data volume $vol_id still $state after 5m — delete manually in AWS console" >&2
  return 1
}

cloud_confirm_destroy() {
  echo
  echo "WARNING: This will destroy the SST stack for stage '$STAGE' ($(cloud_print_context))."
  echo "  - EC2 instance swe-bench-runner-$STAGE"
  echo "  - IAM role, security group, volume attachment"
  echo "  - Data EBS volume swe-bench-runner-$STAGE-data will be RETAINED (~\$24/mo for 300 GiB gp3)"
  echo "    Run ./scripts/destroy_data.sh $STAGE to delete the volume."
  echo
  read -r -p "Continue? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
  echo
  read -r -p "Type '$STAGE' to confirm destroy: " confirm
  if [[ "$confirm" != "$STAGE" ]]; then
    echo "Aborted (confirmation did not match stage name)."
    exit 0
  fi
}

cloud_confirm_destroy_data() {
  local vol_id="$1"
  echo
  echo "WARNING: This will PERMANENTLY delete the data EBS volume for stage '$STAGE'."
  echo "  Volume: $vol_id (tag Name=swe-bench-runner-$STAGE-data)"
  echo "  Region/account: $(cloud_print_context)"
  echo "  ALL contents on /data will be lost (Docker images, synced repo, benchmark results)."
  echo
  read -r -p "Continue? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
  echo
  read -r -p "Type '$STAGE' to confirm volume deletion: " confirm
  if [[ "$confirm" != "$STAGE" ]]; then
    echo "Aborted (confirmation did not match stage name)."
    exit 0
  fi
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

ssh_proxy_cmd() {
  local instance_id="$1"
  printf 'aws ssm start-session --target %s --document-name AWS-StartSSHSession --parameters portNumber=%%p' "$instance_id"
}

resolve_ssh_key() {
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    CLOUD_SSH_KEY="$SSH_PRIVATE_KEY"
    CLOUD_SSH_PUB="${SSH_PUBLIC_KEY:-${SSH_PRIVATE_KEY}.pub}"
  elif [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
    CLOUD_SSH_KEY="${HOME}/.ssh/id_ed25519"
    CLOUD_SSH_PUB="${HOME}/.ssh/id_ed25519.pub"
  elif [[ -f "${HOME}/.ssh/id_rsa" ]]; then
    CLOUD_SSH_KEY="${HOME}/.ssh/id_rsa"
    CLOUD_SSH_PUB="${HOME}/.ssh/id_rsa.pub"
  else
    echo "error: no SSH key found (create ~/.ssh/id_ed25519 or set SSH_PRIVATE_KEY)" >&2
    exit 1
  fi
  if [[ ! -f "$CLOUD_SSH_KEY" || ! -f "$CLOUD_SSH_PUB" ]]; then
    echo "error: SSH key pair not found ($CLOUD_SSH_KEY / $CLOUD_SSH_PUB)" >&2
    exit 1
  fi
}

# sshd still requires a key; SSM only replaces the network path. Push a 60s key via EC2 Instance Connect.
push_ec2_ssh_key() {
  local instance_id="$1"
  resolve_ssh_key
  if ! aws ec2-instance-connect send-ssh-public-key \
    --instance-id "$instance_id" \
    --instance-os-user "$REMOTE_USER" \
    --ssh-public-key "file://${CLOUD_SSH_PUB}" \
    --output text >/dev/null 2>&1; then
    echo "error: failed to push SSH key via EC2 Instance Connect" >&2
    echo "  IAM needs: ec2-instance-connect:SendSSHPublicKey" >&2
    echo "  instance needs: ec2-instance-connect package (redeploy or: sudo apt-get install -y ec2-instance-connect)" >&2
    exit 1
  fi
}

# Ensure /opt/swe-bench -> /data/swe-bench is writable by ubuntu (fixes bootstrap race / root-owned /opt).
ensure_runner_layout() {
  ssh_cmd "bash -s" "$REPO_PATH" "$MINI_SWE_RUNS_PATH" <<'REMOTE'
set -euo pipefail
repo="$1"
msr="$2"
sudo mkdir -p /data/swe-bench /data/docker /data/tmp
sudo chown -R ubuntu:ubuntu /data
if [[ -d "$repo" && ! -L "$repo" ]]; then
  sudo rm -rf "$repo"
fi
if [[ ! -e "$repo" ]]; then
  sudo ln -sfn /data/swe-bench "$repo"
fi
sudo chown -h ubuntu:ubuntu "$repo" 2>/dev/null || true
mkdir -p "$msr"
REMOTE
}

# uv is installed to /usr/local/bin at bootstrap; non-interactive SSH often has a minimal PATH.
ensure_uv() {
  ssh_cmd "bash -s" <<'REMOTE'
set -euo pipefail
export PATH="/usr/local/bin:/home/ubuntu/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [[ -x /usr/local/bin/uv ]]; then
  /usr/local/bin/uv --version
  exit 0
fi
if command -v uv >/dev/null 2>&1; then
  uv --version
  exit 0
fi
echo "Installing uv ..."
curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/home/ubuntu/.local/bin sh
export PATH="/home/ubuntu/.local/bin:$PATH"
uv --version
REMOTE
}

# Populate CLOUD_SSH_OPENSSH_ARGS for ssh/scp (ProxyCommand must stay one argument).
build_ssh_openssh_args() {
  local instance_id="$1"
  CLOUD_SSH_OPENSSH_ARGS=(
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${CLOUD_KNOWN_HOSTS}"
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=QUIET
    -o "ProxyCommand=$(ssh_proxy_cmd "$instance_id")"
  )
}

# SSH/scp/rsync over SSM (no inbound port 22).
ssh_cmd() {
  require_ssm_plugin
  local instance_id
  instance_id="$(get_instance_id)"
  push_ec2_ssh_key "$instance_id"
  resolve_ssh_key
  build_ssh_openssh_args "$instance_id"
  ssh -i "$CLOUD_SSH_KEY" "${CLOUD_SSH_OPENSSH_ARGS[@]}" \
    "${REMOTE_USER}@${instance_id}" "$@"
}

scp_to_remote() {
  local local_path="$1"
  local remote_path="$2"
  local instance_id
  instance_id="$(get_instance_id)"
  push_ec2_ssh_key "$instance_id"
  resolve_ssh_key
  build_ssh_openssh_args "$instance_id"
  scp -i "$CLOUD_SSH_KEY" "${CLOUD_SSH_OPENSSH_ARGS[@]}" \
    "$local_path" "${REMOTE_USER}@${instance_id}:${remote_path}"
}

rsync_to_remote() {
  local instance_id
  instance_id="$(get_instance_id)"
  push_ec2_ssh_key "$instance_id"
  resolve_ssh_key
  rsync -az --delete \
    -e "ssh -i ${CLOUD_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${CLOUD_KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null -o LogLevel=QUIET -o ProxyCommand='$(ssh_proxy_cmd "$instance_id")'" \
    "$@"
}

rsync_from_remote() {
  local instance_id
  instance_id="$(get_instance_id)"
  push_ec2_ssh_key "$instance_id"
  resolve_ssh_key
  rsync -az \
    -e "ssh -i ${CLOUD_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${CLOUD_KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null -o LogLevel=QUIET -o ProxyCommand='$(ssh_proxy_cmd "$instance_id")'" \
    "$@"
}

remote_exec() {
  ssh_cmd "$@"
}

# Interactive SSH (exec replaces this shell — functions cannot be exec'd directly).
ssh_interactive() {
  require_ssm_plugin
  local instance_id
  instance_id="$(get_instance_id)"
  push_ec2_ssh_key "$instance_id"
  resolve_ssh_key
  build_ssh_openssh_args "$instance_id"
  exec ssh -i "$CLOUD_SSH_KEY" "${CLOUD_SSH_OPENSSH_ARGS[@]}" \
    "${REMOTE_USER}@${instance_id}" "$@"
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
  echo "error: instance $instance_id not Online in SSM after 5m" >&2
  return 1
}

wait_ssm_command() {
  local cmd_id="$1"
  local instance_id="$2"
  local i status
  for i in $(seq 1 120); do
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

ssm_send_script() {
  local instance_id="$1"
  local comment="$2"
  local script_file="$3"
  local params tmp
  params="$(mktemp)"
  tmp="$(mktemp)"
  cp "$script_file" "$tmp"
  python3 - "$tmp" "$params" <<'PY'
import json, sys
script = open(sys.argv[1]).read()
json.dump({"commands": [script]}, open(sys.argv[2], "w"))
PY
  local cmd_id
  cmd_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "file://$params" \
    --query Command.CommandId \
    --output text)"
  rm -f "$params" "$tmp"
  wait_ssm_command "$cmd_id" "$instance_id"
}

remote_bootstrap() {
  local instance_id="$1"
  local bootstrap="$CLOUD_DIR/user-data/bootstrap.sh"
  [[ -f "$bootstrap" ]] || { echo "error: missing $bootstrap" >&2; return 1; }
  echo "SSM bootstrap on $instance_id ..."
  local wrapper params cmd_id
  params="$(mktemp)"
  wrapper="$(mktemp)"
  python3 - "$bootstrap" "$wrapper" <<'PY'
import base64, sys
b64 = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
open(sys.argv[2], "w").write(f"echo {b64} | base64 -d | sudo bash\n")
PY
  python3 - "$wrapper" "$params" <<'PY'
import json, sys
script = open(sys.argv[1]).read()
json.dump({"commands": [script]}, open(sys.argv[2], "w"))
PY
  cmd_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "swe-bench-runner bootstrap ($STAGE)" \
    --parameters "file://$params" \
    --query Command.CommandId \
    --output text)"
  rm -f "$params" "$wrapper"
  wait_ssm_command "$cmd_id" "$instance_id"
}

check_runner_ready() {
  local instance_id="$1"
  echo "Readiness check on $instance_id ..."
  local script params
  script="$(mktemp)"
  params="$(mktemp)"
  cat > "$script" <<'SCRIPT'
set -euo pipefail
command -v docker >/dev/null
docker info >/dev/null
getent group docker | grep -qw ubuntu
sudo -u ubuntu sg docker -c "docker info >/dev/null"
test -x /usr/local/bin/uv || command -v uv >/dev/null
test -e /opt/swe-bench
echo "ready: docker=$(docker --version) uv=$(/usr/local/bin/uv --version 2>/dev/null || uv --version)"
SCRIPT
  python3 - "$script" "$params" <<'PY'
import json, sys
script = open(sys.argv[1]).read()
json.dump({"commands": ["bash -c " + json.dumps(script)]}, open(sys.argv[2], "w"))
PY
  local cmd_id
  cmd_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "swe-bench-runner readiness ($STAGE)" \
    --parameters "file://$params" \
    --query Command.CommandId \
    --output text)"
  rm -f "$script" "$params"
  wait_ssm_command "$cmd_id" "$instance_id"
}
