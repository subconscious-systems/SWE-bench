#!/usr/bin/env bash
# Usage: ./scripts/status.sh <stage> [RUN_NAME] [resume_epoch]
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
cloud_parse_run_name "${1:-}"
shift || true
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/status.sh $(printf '%q' "$RUN_NAME")${1:+ $(printf '%q' "$1")}"
