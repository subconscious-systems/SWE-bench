#!/usr/bin/env bash
# Zip results/<RUN_NAME>/ (full tree) and upload to Cloudflare R2.
#
# Usage:
#   ./scripts/upload-results.sh <stage> [RUN_NAME]
#   ./scripts/upload-results.sh <stage> [RUN_NAME] --local
#   ./scripts/upload-results.sh <stage> [RUN_NAME] --force
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

RUN_NAME_ARG=""
LOCAL=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --force) FORCE=1 ;;
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

LIB="$(cd "$(dirname "$0")/lib" && pwd)"
ZIP_NAME="swe-bench-${RUN_NAME}.zip"
FORCE_FLAG=""
[[ "$FORCE" == "1" ]] && FORCE_FLAG="--force"

echo "upload-results: RUN_NAME=$RUN_NAME"

if [[ "$LOCAL" == "1" ]]; then
  RESULTS_PARENT="$REPO_ROOT/mini-swe-runs/results"
  ZIP="/tmp/$ZIP_NAME"
  echo "[1/2] zipping results/$RUN_NAME/ ..."
  bash "$LIB/zip-results.sh" "$RESULTS_PARENT" "$RUN_NAME" "$ZIP"
  echo "[2/2] uploading to R2 ..."
  (
    cd "$REPO_ROOT/mini-swe-runs"
    # shellcheck source=lib/r2-common.sh
    source "$LIB/r2-common.sh"
    r2_load_env
    bash "$LIB/r2-upload.sh" "$ZIP" "$(r2_object_key "$RUN_NAME")" $FORCE_FLAG
  )
  rm -f "$ZIP"
  exit 0
fi

require_aws
REMOTE_ZIP="/data/tmp/$ZIP_NAME"
[[ -d /data/tmp ]] 2>/dev/null || REMOTE_ZIP="/tmp/$ZIP_NAME"

FORCE_REMOTE=""
[[ "$FORCE" == "1" ]] && FORCE_REMOTE="--force"

remote_exec "set -euo pipefail
cd '$MINI_SWE_RUNS_PATH'
echo 'upload-results: RUN_NAME=$RUN_NAME'
echo '[1/2] zipping results/$RUN_NAME/ ...'
bash '$REPO_PATH/cloud/scripts/lib/zip-results.sh' 'results' '$RUN_NAME' '$REMOTE_ZIP'
echo '[2/2] uploading to R2 ...'
source '$REPO_PATH/cloud/scripts/lib/r2-common.sh'
r2_ensure_tools
r2_load_env .env
bash '$REPO_PATH/cloud/scripts/lib/r2-upload.sh' '$REMOTE_ZIP' \"\$(r2_object_key '$RUN_NAME')\" $FORCE_REMOTE
rm -f '$REMOTE_ZIP'
"
