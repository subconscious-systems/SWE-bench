#!/usr/bin/env bash
# Permanently delete the data EBS volume for a stage. Volume must be detached (run destroy.sh first).
# Usage: ./scripts/destroy_data.sh <stage>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

DATA_VOLUME_ID="$(get_data_volume_id)" || {
  echo "error: no data volume found for stage $STAGE (Name=swe-bench-runner-${STAGE}-data)" >&2
  exit 1
}

VOL_STATE="$(aws ec2 describe-volumes \
  --volume-ids "$DATA_VOLUME_ID" \
  --query 'Volumes[0].State' \
  --output text)"

if [[ "$VOL_STATE" == "in-use" ]]; then
  ATTACHED="$(aws ec2 describe-volumes \
    --volume-ids "$DATA_VOLUME_ID" \
    --query 'Volumes[0].Attachments[0].InstanceId' \
    --output text 2>/dev/null || true)"
  if [[ -n "$ATTACHED" && "$ATTACHED" != "None" ]]; then
    INST_STATE="$(aws ec2 describe-instances \
      --instance-ids "$ATTACHED" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || echo terminated)"
    if [[ "$INST_STATE" != "terminated" && "$INST_STATE" != "None" && -n "$INST_STATE" ]]; then
      echo "error: data volume $DATA_VOLUME_ID is still attached to instance $ATTACHED ($INST_STATE)." >&2
      echo "Run ./scripts/destroy.sh $STAGE first to terminate the stack and detach the volume." >&2
      exit 1
    fi
  fi
  echo "Volume is detaching; delete will wait until it is available."
fi

cloud_confirm_destroy_data "$DATA_VOLUME_ID"

echo
echo "Deleting data volume $DATA_VOLUME_ID ..."
delete_data_volume "$DATA_VOLUME_ID"
