#!/usr/bin/env bash
# Zip a results directory and upload to Cloudflare R2.
#
# Usage:
#   ./scripts/upload-results.sh <stage> [RUN_NAME]
#   ./scripts/upload-results.sh <stage> [RUN_NAME] --trajectories
#   ./scripts/upload-results.sh <stage> [RUN_NAME] --local
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

RUN_NAME_ARG=""
LOCAL=0
TRAJ=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --trajectories) TRAJ=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *)
      if [[ -n "$RUN_NAME_ARG" ]]; then
        echo "extra arg: $arg" >&2
        exit 1
      fi
      RUN_NAME_ARG="$arg"
      ;;
  esac
done
cloud_parse_run_name "${RUN_NAME_ARG:-}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="swe-bench-${RUN_NAME}-${TS}.zip"
LIB="$(dirname "$0")/lib"

if [[ "$LOCAL" == "1" ]]; then
  RESULTS="$REPO_ROOT/mini-swe-runs/results/$RUN_NAME"
  ZIP="/tmp/$ZIP_NAME"
  bash "$LIB/zip-results.sh" "$RESULTS" "$ZIP" $([[ "$TRAJ" == "1" ]] && echo --trajectories)
  (cd "$REPO_ROOT/mini-swe-runs" && bash "$CLOUD_DIR/scripts/lib/r2-upload.sh" "$ZIP" "$RUN_NAME/$ZIP_NAME")
  exit 0
fi

require_aws
REMOTE_RESULTS="$MINI_SWE_RUNS_PATH/results/$RUN_NAME"
REMOTE_ZIP="/data/tmp/$ZIP_NAME"
[[ -d /data/tmp ]] 2>/dev/null || REMOTE_ZIP="/tmp/$ZIP_NAME"

TRAJ_FLAG=""
[[ "$TRAJ" == "1" ]] && TRAJ_FLAG="--trajectories"

remote_exec "set -euo pipefail
cd '$MINI_SWE_RUNS_PATH'
bash '$REPO_PATH/cloud/scripts/lib/zip-results.sh' 'results/$RUN_NAME' '$REMOTE_ZIP' $TRAJ_FLAG
source .env
bash '$REPO_PATH/cloud/scripts/lib/r2-upload.sh' '$REMOTE_ZIP' '$RUN_NAME/$ZIP_NAME'
rm -f '$REMOTE_ZIP'
"
