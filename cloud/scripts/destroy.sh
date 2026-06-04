#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

echo "WARNING: This removes the SST stack ($(cloud_print_context))."
echo "The data EBS volume is set to retainOnDelete — verify in AWS console if you need it."
read -r -p "Continue? [y/N] " ans
case "$ans" in [yY]|[yY][eE][sS]) ;; *) exit 0 ;; esac

npm install --silent 2>/dev/null || true
npx sst remove --stage "$STAGE"
