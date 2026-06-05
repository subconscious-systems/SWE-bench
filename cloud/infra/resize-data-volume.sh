#!/usr/bin/env bash
# Grow the stage data EBS volume in place and extend the ext4 filesystem on /data.
#
# Usage: ./infra/resize-data-volume.sh <stage> [SIZE_GB]
#   SIZE_GB defaults to 500
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

TARGET_GB="${1:-500}"
if [[ ! "$TARGET_GB" =~ ^[0-9]+$ ]] || [[ "$TARGET_GB" -lt 1 ]]; then
  echo "error: SIZE_GB must be a positive integer (got: $TARGET_GB)" >&2
  exit 1
fi

require_aws
INSTANCE_ID="$(get_instance_id)"
VOLUME_ID="$(aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=swe-bench-runner-${STAGE}-data" \
  --query 'Volumes[0].VolumeId' \
  --output text 2>/dev/null || true)"

if [[ -z "$VOLUME_ID" || "$VOLUME_ID" == "None" ]]; then
  VOLUME_ID="$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/sdf'].Ebs.VolumeId | [0]" \
    --output text)"
fi

if [[ -z "$VOLUME_ID" || "$VOLUME_ID" == "None" ]]; then
  echo "error: no data volume found for stage $STAGE" >&2
  exit 1
fi

CURRENT_GB="$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --query 'Volumes[0].Size' \
  --output text)"

echo "stage=$STAGE instance=$INSTANCE_ID volume=$VOLUME_ID"
echo "current size: ${CURRENT_GB} GiB → target: ${TARGET_GB} GiB"

if [[ "$CURRENT_GB" -ge "$TARGET_GB" ]]; then
  echo "volume already >= ${TARGET_GB} GiB; extending filesystem only if needed ..."
else
  echo "Modifying EBS volume ..."
  aws ec2 modify-volume --volume-id "$VOLUME_ID" --size "$TARGET_GB" --output text >/dev/null

  echo "Waiting for volume modification ..."
  for _ in $(seq 1 120); do
    state="$(aws ec2 describe-volumes-modifications \
      --volume-ids "$VOLUME_ID" \
      --query 'VolumesModifications[0].ModificationState' \
      --output text 2>/dev/null || echo optimizing)"
    case "$state" in
      completed|optimizing) break ;;
      failed)
        echo "error: volume modification failed" >&2
        exit 1
        ;;
    esac
    sleep 5
  done
fi

echo "Extending ext4 on instance ..."
remote_exec "set -euo pipefail
echo '--- before ---'
df -h /data
DATA_DEV=\"\"
for d in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
  if mountpoint -q /data && [[ \"\$(findmnt -n -o SOURCE /data)\" == \"\$d\" ]]; then
    DATA_DEV=\"\$d\"
    break
  fi
done
if [[ -z \"\$DATA_DEV\" ]]; then
  for d in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
    if [[ -b \"\$d\" ]]; then DATA_DEV=\"\$d\"; break; fi
  done
fi
if [[ -z \"\$DATA_DEV\" ]]; then
  echo 'error: could not find /data block device' >&2
  exit 1
fi
sudo resize2fs \"\$DATA_DEV\"
echo '--- after ---'
df -h /data
"

echo "Done: /data resized to ${TARGET_GB} GiB (or already larger)."
