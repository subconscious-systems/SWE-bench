#!/usr/bin/env bash
# Zip results/<RUN_NAME>/ mirroring the local directory tree.
#
# Usage: zip-results.sh <RESULTS_PARENT> <RUN_NAME> <OUTPUT_ZIP>
#   RESULTS_PARENT is the directory containing RUN_NAME (e.g. .../mini-swe-runs/results)
#   Zip root contains RUN_NAME/ as the top-level entry.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <RESULTS_PARENT> <RUN_NAME> <OUTPUT_ZIP>" >&2
  exit 2
fi

RESULTS_PARENT="$(cd "$1" && pwd)"
RUN_NAME="$2"
OUTPUT_ZIP="$3"
RUN_DIR="$RESULTS_PARENT/$RUN_NAME"

if [[ -z "$RUN_NAME" || "$RUN_NAME" == */* ]]; then
  echo "error: RUN_NAME must be a bare name, not a path" >&2
  exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "error: results directory not found: $RUN_DIR" >&2
  exit 1
fi

if [[ ! -f "$RUN_DIR/preds.json" ]]; then
  echo "warning: $RUN_DIR/preds.json missing (uploading partial run anyway)" >&2
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "error: zip not found" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ZIP")"
rm -f "$OUTPUT_ZIP"

file_count="$(find "$RUN_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
dir_size="$(du -sh "$RUN_DIR" 2>/dev/null | cut -f1)"
echo "zipping $RUN_NAME/ ($file_count files, $dir_size) ..."

(
  cd "$RESULTS_PARENT"
  # List entries as they are added (progress over slow / large trees).
  zip -r "$OUTPUT_ZIP" "$RUN_NAME/"
)

echo "created $OUTPUT_ZIP ($(du -h "$OUTPUT_ZIP" | cut -f1))"
