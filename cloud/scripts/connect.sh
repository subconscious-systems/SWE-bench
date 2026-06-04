#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"
require_aws
INSTANCE_ID="$(get_instance_id)"
exec aws ssm start-session --target "$INSTANCE_ID"
