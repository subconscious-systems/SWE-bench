#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

echo "Running uv sync --frozen in $MINI_SWE_RUNS_PATH ..."
remote_exec "cd '$MINI_SWE_RUNS_PATH' && uv sync --frozen"
echo "Done. Use: uv run mini-extra, uv run pier (from $MINI_SWE_RUNS_PATH on the instance)"
