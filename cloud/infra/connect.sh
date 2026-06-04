#!/usr/bin/env bash
# SSM shell as ubuntu (no SSH key). Prefer ./infra/ssh.sh for full SSH/rsync parity.
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
require_ssm_plugin
INSTANCE_ID="$(get_instance_id)"

# AWS-StartInteractiveCommand: land in ubuntu's login shell under mini-swe-runs when present.
CMD="sudo -iu ubuntu bash -lc 'cd \"${MINI_SWE_RUNS_PATH}\" 2>/dev/null || cd ~; exec bash -l'"
exec aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartInteractiveCommand \
  --parameters "command=${CMD}"
