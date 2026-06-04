#!/usr/bin/env bash
# Pull results from EC2 to local mini-swe-runs/results/
#
# Usage: ./scripts/pull-results.sh <stage> [run_dir] [--trajectories] [--logs]
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

RUN_DIR=""
TRAJ=0
LOGS=0
for arg in "$@"; do
  case "$arg" in
    --trajectories) TRAJ=1 ;;
    --logs) LOGS=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) RUN_DIR="$arg" ;;
  esac
done
RUN_DIR="${RUN_DIR:-verified-full-v2}"

require_aws
LOCAL_DIR="$REPO_ROOT/mini-swe-runs/results/$RUN_DIR"
mkdir -p "$LOCAL_DIR"
REMOTE_BASE="$MINI_SWE_RUNS_PATH/results/$RUN_DIR"

echo "Pulling $RUN_DIR -> $LOCAL_DIR"

ssh_cmd "bash -s" "$REMOTE_BASE" <<'TAR' | tar xzf - -C "$LOCAL_DIR" 2>/dev/null || true
set -euo pipefail
D="$1"
cd "$D"
shopt -s nullglob
TO_TAR=(preds.json minisweagent.log exit_statuses_*.yaml *.json)
[[ ${#TO_TAR[@]} -gt 0 ]] || exit 0
tar czf - "${TO_TAR[@]}"
TAR

if [[ "$LOGS" == "1" ]]; then
  INSTANCE_ID="$(get_instance_id)"
  mkdir -p "$LOCAL_DIR/logs"
  rsync_from_remote -r \
    "${REMOTE_USER}@${INSTANCE_ID}:${REMOTE_BASE}/logs/" \
    "$LOCAL_DIR/logs/" || true
fi

if [[ "$TRAJ" == "1" ]]; then
  INSTANCE_ID="$(get_instance_id)"
  rsync_from_remote -r \
    "${REMOTE_USER}@${INSTANCE_ID}:${REMOTE_BASE}/" \
    "$LOCAL_DIR/" \
    --include '*/' \
    --include '*.traj.json' \
    --exclude '*'
fi

echo "Done: $LOCAL_DIR"
