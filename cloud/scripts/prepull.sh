#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"
require_aws
remote_exec "cd '$MINI_SWE_RUNS_PATH' && ./scripts/prepull.sh $*"
