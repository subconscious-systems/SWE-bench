#!/usr/bin/env bash
# Build a zip archive for a SWE-bench results directory.
# Usage: zip-results.sh <results_dir> <output.zip> [--trajectories]
set -euo pipefail

RESULTS_DIR="${1:?results dir}"
OUT_ZIP="${2:?output zip}"
INCLUDE_TRAJ=0
shift 2 || true
for arg in "$@"; do
  [[ "$arg" == "--trajectories" ]] && INCLUDE_TRAJ=1
done

[[ -d "$RESULTS_DIR" ]] || { echo "error: not a directory: $RESULTS_DIR" >&2; exit 1; }
[[ -f "$RESULTS_DIR/preds.json" ]] || { echo "error: no preds.json in $RESULTS_DIR" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
STAGE="$WORKDIR/stage"
mkdir -p "$STAGE"
RUN_NAME="$(basename "$RESULTS_DIR")"
mkdir -p "$STAGE/$RUN_NAME"

cp "$RESULTS_DIR/preds.json" "$STAGE/$RUN_NAME/"
cp "$RESULTS_DIR"/minisweagent.log "$STAGE/$RUN_NAME/" 2>/dev/null || true
cp "$RESULTS_DIR"/exit_statuses_*.yaml "$STAGE/$RUN_NAME/" 2>/dev/null || true
cp "$RESULTS_DIR"/*.*.json "$STAGE/$RUN_NAME/" 2>/dev/null || true
[[ -d "$RESULTS_DIR/logs" ]] && cp -a "$RESULTS_DIR/logs" "$STAGE/$RUN_NAME/"

if [[ "$INCLUDE_TRAJ" == "1" ]]; then
  for d in "$RESULTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    [[ "$base" == "logs" ]] && continue
    if compgen -G "${d}*.traj.json" >/dev/null; then
      mkdir -p "$STAGE/$RUN_NAME/$base"
      cp "${d}"*.traj.json "$STAGE/$RUN_NAME/$base/" 2>/dev/null || true
    fi
  done
fi

rm -f "$OUT_ZIP"
OUT_ABS="$(cd "$(dirname "$OUT_ZIP")" && pwd)/$(basename "$OUT_ZIP")"
(
  cd "$STAGE"
  zip -qr "$OUT_ABS" "$RUN_NAME"
)
echo "$OUT_ABS"
