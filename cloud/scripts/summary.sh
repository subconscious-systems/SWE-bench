#!/usr/bin/env bash
# Usage: ./scripts/summary.sh <stage> [RUN_NAME]
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
cloud_parse_run_name "${1:-}"
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/summary.sh $(printf '%q' "$RUN_NAME")"
