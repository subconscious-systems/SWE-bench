#!/usr/bin/env bash
# Download results/<RUN_NAME>/ archive from R2 and unzip into results/.
#
# Usage:
#   ./scripts/restore-results.sh <stage> [RUN_NAME]
#   ./scripts/restore-results.sh <stage> [RUN_NAME] --local
#   ./scripts/restore-results.sh <stage> [RUN_NAME] --force
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

restore_unzip() {
  local zip_path="$1"
  local results_parent="$2"
  local run_dir="$results_parent/$RUN_NAME"

  if [[ -d "$run_dir" ]] && [[ "$FORCE" != "1" ]]; then
    echo "warning: results directory already exists: $run_dir" >&2
    if [[ -t 0 ]]; then
      read -r -p "Overwrite by merging unzip? [y/N] " ans
      case "$ans" in
        [yY]|[yY][eE][sS]) ;;
        *)
          echo "error: re-run with --force to restore over existing results" >&2
          exit 1
          ;;
      esac
    else
      echo "error: re-run with --force to restore over existing results" >&2
      exit 1
    fi
  fi

  mkdir -p "$results_parent"
  if ! command -v unzip >/dev/null 2>&1; then
    echo "error: unzip not found" >&2
    exit 1
  fi
  unzip -o "$zip_path" -d "$results_parent"
  rm -f "$zip_path"

  if [[ -f "$run_dir/preds.json" ]]; then
    count="$(python3 -c "import json; print(len(json.load(open('$run_dir/preds.json'))))" 2>/dev/null || echo 0)"
    echo "restored $run_dir ($count preds in preds.json)"
  else
    echo "restored $run_dir (no preds.json yet)"
  fi
  echo "resume: re-run the same run.sh / run-tmux.sh with RUN_NAME=$RUN_NAME"
}

if [[ "$LOCAL" == "1" ]]; then
  RESULTS_PARENT="$REPO_ROOT/mini-swe-runs/results"
  ZIP="/tmp/$ZIP_NAME"
  (
    cd "$REPO_ROOT/mini-swe-runs"
    # shellcheck source=lib/r2-common.sh
    source "$LIB/r2-common.sh"
    r2_load_env
    bash "$LIB/r2-download.sh" "$(r2_object_key "$RUN_NAME")" "$ZIP"
  )
  restore_unzip "$ZIP" "$RESULTS_PARENT"
  exit 0
fi

require_aws
REMOTE_RESULTS_PARENT="$MINI_SWE_RUNS_PATH/results"
REMOTE_ZIP="/data/tmp/$ZIP_NAME"
[[ -d /data/tmp ]] 2>/dev/null || REMOTE_ZIP="/tmp/$ZIP_NAME"

remote_exec "set -euo pipefail
cd '$MINI_SWE_RUNS_PATH'
source '$REPO_PATH/cloud/scripts/lib/r2-common.sh'
r2_load_env .env
bash '$REPO_PATH/cloud/scripts/lib/r2-download.sh' \"\$(r2_object_key '$RUN_NAME')\" '$REMOTE_ZIP'

RUN_DIR='$REMOTE_RESULTS_PARENT/$RUN_NAME'
if [[ -d \"\$RUN_DIR\" ]] && [[ '$FORCE' != '1' ]]; then
  echo 'warning: results directory already exists: '\$RUN_DIR >&2
  echo 'error: re-run with --force to restore over existing results' >&2
  rm -f '$REMOTE_ZIP'
  exit 1
fi

mkdir -p '$REMOTE_RESULTS_PARENT'
unzip -o '$REMOTE_ZIP' -d '$REMOTE_RESULTS_PARENT'
rm -f '$REMOTE_ZIP'

if [[ -f \"\$RUN_DIR/preds.json\" ]]; then
  count=\$(python3 -c \"import json; print(len(json.load(open('\$RUN_DIR/preds.json'))))\" 2>/dev/null || echo 0)
  echo \"restored \$RUN_DIR (\$count preds in preds.json)\"
else
  echo \"restored \$RUN_DIR (no preds.json yet)\"
fi
echo 'resume: re-run the same run.sh / run-tmux.sh with RUN_NAME=$RUN_NAME'
"
