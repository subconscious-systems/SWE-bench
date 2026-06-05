#!/usr/bin/env bash
# SSM escape hatch: run a local script file on the instance as root WITHOUT
# SSH or a synced repo. Only bootstrap (and pre-sync readiness) need this —
# everything else goes over SSH to scripts that arrived via git sync.
# Source only.
set -euo pipefail

# ssm_run_script <instance_id> <comment> <local_script_path>
# Base64-wraps the script so it survives SSM/shell quoting as a single line.
ssm_run_script() {
  local instance_id="$1"
  local comment="$2"
  local script_file="$3"
  [[ -f "$script_file" ]] || { echo "error: missing $script_file" >&2; return 1; }

  local b64 params cmd_id
  # base64 output is [A-Za-z0-9+/=] — safe to embed in JSON unescaped.
  b64="$(base64 <"$script_file" | tr -d '\n')"
  params="$(mktemp)"
  printf '{"commands":["echo %s | base64 -d | sudo bash"]}' "$b64" >"$params"
  cmd_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "file://$params" \
    --query Command.CommandId \
    --output text)"
  rm -f "$params"
  wait_ssm_command "$cmd_id" "$instance_id"
}
