#!/usr/bin/env bash
# SSH-over-SSM transport — THE single place that defines how the laptop
# reaches an instance (ProxyCommand, key handling, options). Used by plain
# ssh, file upload, interactive shells, and git push. Source only.
set -euo pipefail

CLOUD_KNOWN_HOSTS="${CLOUD_KNOWN_HOSTS:-$CLOUD_DIR/.runner-known-hosts}"
touch "$CLOUD_KNOWN_HOSTS" 2>/dev/null || true
chmod 600 "$CLOUD_KNOWN_HOSTS" 2>/dev/null || true

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

# sshd still requires a key; SSM only replaces the network path. Push a 60s
# key via EC2 Instance Connect (validity only matters at connection time).
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
    echo "  instance needs: ec2-instance-connect package (swb bootstrap installs it)" >&2
    exit 1
  fi
}

# Populate CLOUD_SSH_OPENSSH_ARGS (ProxyCommand must stay one argument).
build_ssh_openssh_args() {
  local instance_id="$1"
  CLOUD_SSH_OPENSSH_ARGS=(
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${CLOUD_KNOWN_HOSTS}"
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=QUIET
    -o ConnectTimeout=30
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o "ProxyCommand=$(ssh_proxy_cmd "$instance_id")"
  )
}

# Prepare transport for one logical operation: key push + args. Sets
# CLOUD_SSH_INSTANCE_ID and CLOUD_SSH_OPENSSH_ARGS.
ssh_prepare() {
  require_ssm_plugin
  CLOUD_SSH_INSTANCE_ID="$(get_instance_id)"
  push_ec2_ssh_key "$CLOUD_SSH_INSTANCE_ID"
  build_ssh_openssh_args "$CLOUD_SSH_INSTANCE_ID"
}

ssh_cmd() {
  ssh_prepare
  ssh -i "$CLOUD_SSH_KEY" "${CLOUD_SSH_OPENSSH_ARGS[@]}" \
    "${REMOTE_USER}@${CLOUD_SSH_INSTANCE_ID}" "$@"
}

# Upload a local file over SSH stdin (more reliable than scp/sftp over SSM).
ssh_upload_file() {
  local local_path="$1"
  local remote_path="$2"
  local qpath
  qpath="$(printf '%q' "$remote_path")"
  ssh_cmd \
    "set -euo pipefail; dest=$qpath; mkdir -p \"\$(dirname \"\$dest\")\"; tmp=\"\${dest}.push.\$\$\"; cat >\"\$tmp\"; chmod 600 \"\$tmp\"; mv -f \"\$tmp\" \"\$dest\"" \
    <"$local_path"
}

# Interactive SSH (exec replaces this shell).
ssh_interactive() {
  ssh_prepare
  exec ssh -i "$CLOUD_SSH_KEY" "${CLOUD_SSH_OPENSSH_ARGS[@]}" \
    "${REMOTE_USER}@${CLOUD_SSH_INSTANCE_ID}" "$@"
}

# Print a GIT_SSH_COMMAND string that reuses the exact same transport
# definition, so `git push` and `ssh` can never drift apart.
swb_git_ssh_command() {
  local out a
  out="ssh -i $(printf '%q' "$CLOUD_SSH_KEY")"
  for a in "${CLOUD_SSH_OPENSSH_ARGS[@]}"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "$out"
}
