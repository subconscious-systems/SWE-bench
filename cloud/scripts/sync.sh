#!/usr/bin/env bash
# Rsync repo to EC2 (excludes .env, results, heavy dirs).
#
# Usage: ./scripts/sync.sh <stage> [--install]
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

INSTANCE_ID="$(get_instance_id)"
echo "Syncing $REPO_ROOT -> ${REMOTE_USER}@${INSTANCE_ID}:$REPO_PATH"

rsync_to_remote \
  --exclude '.git/' \
  --exclude 'cloud/node_modules/' \
  --exclude 'cloud/.sst/' \
  --exclude 'mini-swe-runs/.env' \
  --exclude 'mini-swe-runs/.venv/' \
  --exclude 'mini-swe-runs/results/' \
  --exclude 'mini-swe-runs/traces/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  "$REPO_ROOT/" "${REMOTE_USER}@${INSTANCE_ID}:${REPO_PATH}/"

echo "Sync complete."
if [[ "$INSTALL" == "1" ]]; then
  exec "$(dirname "$0")/install-deps.sh" "$STAGE"
fi
