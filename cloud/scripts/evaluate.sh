#!/usr/bin/env bash
# Usage: ./scripts/evaluate.sh <stage> ...
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/evaluate.sh $*"
