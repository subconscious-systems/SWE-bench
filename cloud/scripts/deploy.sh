#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

require_aws

echo "Deploying swe-bench-runner (stage=$STAGE, region=$AWS_REGION)..."
if [[ -n "${AWS_PROFILE:-}" ]]; then
  echo "Using AWS_PROFILE=$AWS_PROFILE"
fi

npm install --silent 2>/dev/null || npm install
npx sst deploy --stage "$STAGE"

INSTANCE_ID="$(get_instance_id)"
echo
echo "Instance: $INSTANCE_ID"
echo "Wait for SSM/SSH (bootstrap may take a few minutes on first boot)..."
wait_for_ssm "$INSTANCE_ID" || true
echo
echo "Next:"
echo "  ./scripts/push-env.sh"
echo "  ./scripts/sync.sh"
echo "  ./scripts/install-deps.sh"
