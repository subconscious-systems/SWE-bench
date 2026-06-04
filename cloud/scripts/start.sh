#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
INSTANCE_ID="$(get_instance_id)"
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --output text
echo "Starting $INSTANCE_ID..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
wait_for_ssm "$INSTANCE_ID" || true
echo "Instance running. SSM/SSH should be available shortly."
