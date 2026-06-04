#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

echo "Deploying swe-bench-runner ($(cloud_print_context))..."

npm install --silent 2>/dev/null || npm install
npx sst deploy --stage "$STAGE"

INSTANCE_ID="$(get_instance_id)"
echo
echo "Instance: $INSTANCE_ID"
echo "Wait for SSM/SSH (bootstrap may take a few minutes on first boot)..."
wait_for_ssm "$INSTANCE_ID" || true
echo
echo "Next:"
echo "  ./scripts/push-env.sh $STAGE"
echo "  ./scripts/sync.sh $STAGE --install"
