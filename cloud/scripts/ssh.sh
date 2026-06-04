#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
exec ssh_cmd -t "cd $MINI_SWE_RUNS_PATH && exec bash -l"
