#!/usr/bin/env bash
# Usage: ./scripts/prepull.sh <stage> [count]
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/prepull.sh $*"
