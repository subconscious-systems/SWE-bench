#!/usr/bin/env bash
# Usage: ./scripts/evaluate.sh <stage> [RUN_NAME] [run_id] ...
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

REMOTE_ARGS=()
if [[ $# -gt 0 ]]; then
  cloud_parse_run_name "$1"
  shift
  REMOTE_ARGS+=("$RUN_NAME")
fi
REMOTE_ARGS+=("$@")

if [[ ${#REMOTE_ARGS[@]} -eq 0 ]]; then
  remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/evaluate.sh"
else
  remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/evaluate.sh $(printf '%q ' "${REMOTE_ARGS[@]}")"
fi
