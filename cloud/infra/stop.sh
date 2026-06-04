#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
INSTANCE_ID="$(get_instance_id)"
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --output text
echo "Stopping $INSTANCE_ID (EBS data persists; no compute charge while stopped)"
