#!/usr/bin/env bash
# Zip a results directory and upload to Cloudflare R2.
# Usage:
#   ./upload-results.sh verified-full-v2
#   ./upload-results.sh verified-full-v2 --trajectories
#   ./upload-results.sh verified-full-v2 --local
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

RUN_DIR=""
LOCAL=0
TRAJ=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --trajectories) TRAJ=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *)
      if [[ -z "$RUN_DIR" ]]; then RUN_DIR="$arg"; else echo "extra arg: $arg" >&2; exit 1; fi
      ;;
  esac
done

RUN_DIR="${RUN_DIR:-verified-full-v2}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="swe-bench-${RUN_DIR}-${TS}.zip"
LIB="$(dirname "$0")/lib"

if [[ "$LOCAL" == "1" ]]; then
  RESULTS="$REPO_ROOT/mini-swe-runs/results/$RUN_DIR"
  ZIP="/tmp/$ZIP_NAME"
  bash "$LIB/zip-results.sh" "$RESULTS" "$ZIP" $([[ "$TRAJ" == "1" ]] && echo --trajectories)
  (cd "$REPO_ROOT/mini-swe-runs" && bash "$CLOUD_DIR/scripts/lib/r2-upload.sh" "$ZIP" "$RUN_DIR/$ZIP_NAME")
  exit 0
fi

require_aws
REMOTE_RESULTS="$MINI_SWE_RUNS_PATH/results/$RUN_DIR"
REMOTE_ZIP="/data/tmp/$ZIP_NAME"
[[ -d /data/tmp ]] 2>/dev/null || REMOTE_ZIP="/tmp/$ZIP_NAME"

TRAJ_FLAG=""
[[ "$TRAJ" == "1" ]] && TRAJ_FLAG="--trajectories"

remote_exec "set -euo pipefail
cd '$MINI_SWE_RUNS_PATH'
bash '$REPO_PATH/cloud/scripts/lib/zip-results.sh' 'results/$RUN_DIR' '$REMOTE_ZIP' $TRAJ_FLAG
source .env
bash '$REPO_PATH/cloud/scripts/lib/r2-upload.sh' '$REMOTE_ZIP' '$RUN_DIR/$ZIP_NAME'
rm -f '$REMOTE_ZIP'
"
