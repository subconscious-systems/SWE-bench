#!/usr/bin/env bash
# Tear down an SST stage (EC2 stack + data EBS volume). Destructive — export data first.
# Usage: ./infra/destroy.sh <stage>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

if ! runner_stack_exists; then
  echo "Nothing to destroy for stage $STAGE (no active EC2 stack)." >&2
  echo "If an orphaned data volume remains from an older deploy (retainOnDelete), delete it in the AWS console." >&2
  exit 1
fi

cloud_confirm_destroy

echo
echo "Removing SST stack (instance + data volume) ..."
npm install --silent 2>/dev/null || true
npx sst remove --stage "$STAGE"

echo
echo "Stack removed. EC2 instance and data volume swe-bench-runner-${STAGE}-data are deleted."
