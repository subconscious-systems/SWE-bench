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
echo "Waiting for SSM ..."
wait_for_ssm "$INSTANCE_ID"

echo
echo "Stack deployed. Bootstrap the instance next:"
echo "  ./infra/bootstrap.sh $STAGE"
echo
echo "Then:"
echo "  ./infra/push-env.sh $STAGE"
echo "  ./infra/sync.sh $STAGE --install"
echo "  ./scripts/run.sh $STAGE yaml/qwen/smoke.yaml smoke-qwen"
