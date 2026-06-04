#!/usr/bin/env bash
# Tear down an SST stage (EC2 stack). Data EBS volume is retained — use destroy_data.sh to delete it.
# Usage: ./scripts/destroy.sh <stage>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

if ! runner_stack_exists; then
  echo "Nothing to destroy for stage $STAGE (no active EC2 stack)." >&2
  echo "To delete an orphaned data volume: ./scripts/destroy_data.sh $STAGE" >&2
  exit 1
fi

cloud_confirm_destroy

echo
echo "Removing SST stack ..."
npm install --silent 2>/dev/null || true
npx sst remove --stage "$STAGE"

echo
echo "Stack removed. Data volume retained: swe-bench-runner-${STAGE}-data"
echo "Delete with: ./scripts/destroy_data.sh $STAGE"
