#!/usr/bin/env bash
# Usage: ./scripts/status.sh <stage> [run_dir]
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
RUN_DIR="${1:-results/verified-full-v2}"
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/status.sh '$RUN_DIR' ${2:+"$2"}"
