#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
INSTANCE_ID="$(get_instance_id)"
exec aws ssm start-session --target "$INSTANCE_ID"
