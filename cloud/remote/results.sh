#!/usr/bin/env bash
# Zip + upload (push) or download + unzip (restore) benchmark results to/from
# Cloudflare R2. Runs where the results live: on the instance (invoked by
# `swb results push/restore` over SSH) or on a laptop checkout (`--local`).
# All paths are resolved relative to this script, so there is no remote/local
# divergence and no string-interpolated remote heredocs.
#
# Usage: results.sh <push|restore> <RUN_NAME> [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MSR_DIR="$REPO_DIR/mini-swe-runs"
RESULTS_PARENT="$MSR_DIR/results"

# shellcheck source=../lib/r2.sh disable=SC1091
source "$SCRIPT_DIR/../lib/r2.sh"

usage() { echo "usage: $0 <push|restore> <RUN_NAME> [--force]" >&2; exit 2; }

CMD="${1:-}"
RUN_NAME="${2:-}"
FORCE=0
shift 2 2>/dev/null || usage
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

[[ "$CMD" == "push" || "$CMD" == "restore" ]] || usage
if [[ -z "$RUN_NAME" || "$RUN_NAME" == */* ]]; then
  echo "error: RUN_NAME must be a bare name, not a path" >&2
  exit 1
fi

r2_ensure_tools
r2_load_env "$MSR_DIR/.env"

KEY="$(r2_object_key "$RUN_NAME")"
RUN_DIR="$RESULTS_PARENT/$RUN_NAME"
TMP_PARENT="${TMPDIR:-/tmp}"
[[ -d /data/tmp && -w /data/tmp ]] && TMP_PARENT="/data/tmp"
ZIP="$TMP_PARENT/$(r2_zip_basename "$RUN_NAME")"

cleanup() { rm -f "$ZIP"; }
trap cleanup EXIT

push() {
  if [[ ! -d "$RUN_DIR" ]]; then
    echo "error: results directory not found: $RUN_DIR" >&2
    exit 1
  fi
  if [[ ! -f "$RUN_DIR/preds.json" ]]; then
    echo "warning: $RUN_DIR/preds.json missing (uploading partial run anyway)" >&2
  fi
  r2_confirm_overwrite "$KEY" "$FORCE"

  local file_count dir_size
  file_count="$(find "$RUN_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  dir_size="$(du -sh "$RUN_DIR" 2>/dev/null | cut -f1)"
  echo "[1/2] zipping $RUN_NAME/ ($file_count files, $dir_size) ..."
  rm -f "$ZIP"
  (cd "$RESULTS_PARENT" && zip -qr "$ZIP" "$RUN_NAME/")
  echo "created $ZIP ($(du -h "$ZIP" | cut -f1))"

  echo "[2/2] uploading -> $(r2_s3_uri "$KEY") ..."
  r2_aws s3 cp "$ZIP" "$(r2_s3_uri "$KEY")"
  echo "uploaded $(r2_s3_uri "$KEY")"
  if [[ -n "${R2_PUBLIC_BASE_URL:-}" ]]; then
    echo "public: ${R2_PUBLIC_BASE_URL%/}/${KEY}"
  fi
}

restore() {
  if [[ -d "$RUN_DIR" && "$FORCE" != "1" ]]; then
    echo "warning: results directory already exists: $RUN_DIR" >&2
    if [[ -t 0 ]]; then
      read -r -p "Overwrite by merging unzip? [y/N] " ans
      case "$ans" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "error: re-run with --force to restore over existing results" >&2; exit 1 ;;
      esac
    else
      echo "error: re-run with --force to restore over existing results" >&2
      exit 1
    fi
  fi

  echo "[1/2] downloading $(r2_s3_uri "$KEY") ..."
  mkdir -p "$RESULTS_PARENT"
  if ! r2_aws s3 cp "$(r2_s3_uri "$KEY")" "$ZIP"; then
    echo "error: object not found: $(r2_s3_uri "$KEY")" >&2
    echo "  check RUN_NAME, R2_PREFIX, and R2_BUCKET in .env" >&2
    exit 1
  fi

  echo "[2/2] unzipping into results/ ..."
  unzip -qo "$ZIP" -d "$RESULTS_PARENT"

  if [[ -f "$RUN_DIR/preds.json" ]]; then
    local count
    count="$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/preds.json'))))" 2>/dev/null || echo 0)"
    echo "restored $RUN_DIR ($count preds in preds.json)"
  else
    echo "restored $RUN_DIR (no preds.json yet)"
  fi
  echo "resume: swb run --detach <stage> <yaml> $RUN_NAME"
}

"$CMD"
