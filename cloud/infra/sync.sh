#!/usr/bin/env bash
# Rsync repo to EC2 (excludes .env, results, heavy dirs).
#
# Usage: ./infra/sync.sh <stage> [--install] [--fullsync]
#   Default: incremental sync (no --delete; faster over SSM).
#   --fullsync: also delete remote files absent from the repo mirror.
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

INSTALL=0
FULLSYNC=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --fullsync) FULLSYNC=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

INSTANCE_ID="$(get_instance_id)"
echo "Syncing $REPO_ROOT -> ${REMOTE_USER}@${INSTANCE_ID}:$REPO_PATH"
if [[ "$FULLSYNC" == "1" ]]; then
  echo "mode: full sync (--delete enabled)"
else
  echo "mode: incremental (no --delete; use --fullsync to prune remote orphans)"
fi

echo "Checking remote layout ..."
ensure_runner_layout

echo "Rsync in progress ..."
RSYNC_PROGRESS=(--progress --stats)
if rsync --help 2>&1 | grep -q 'progress2'; then
  RSYNC_PROGRESS=(--info=progress2,stats2 --human-readable)
fi

CLOUD_RSYNC_DELETE="$FULLSYNC" rsync_to_remote \
  "${RSYNC_PROGRESS[@]}" \
  --exclude '.git/' \
  --exclude '.cursor/' \
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
