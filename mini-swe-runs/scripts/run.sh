#!/usr/bin/env bash
# Run SWE-bench Verified from a run-spec YAML (all settings live in the yaml file).
#
# Usage: ./scripts/run.sh <yaml-path> <RUN_NAME>
#
# Examples:
#   ./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
#   ./scripts/run.sh yaml/qwen/verified-full-v2.yaml qwen-june
#
# Progress: mini-swe-agent logs to the terminal sparingly; tail the run log:
#   tail -f results/<RUN_NAME>/minisweagent.log
set -euo pipefail

MSR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MSR_ROOT"

# Match EC2 (Ubuntu 3.12) and install-deps; avoid .python-version drift pulling 3.14.
UV_RUN=(uv run --python 3.12)

YAML_PATH="${1:-}"
RUN_NAME="${2:-}"

[[ -n "$YAML_PATH" && -n "$RUN_NAME" ]] || {
  echo "usage: $0 <yaml-path> <RUN_NAME>" >&2
  exit 1
}

[[ -f "$YAML_PATH" ]] || { echo "error: yaml not found: $YAML_PATH" >&2; exit 1; }

eval "$("${UV_RUN[@]}" python scripts/hydrate_run_yaml.py "$YAML_PATH" --bootstrap "$RUN_NAME")"
: "${OUTPUT_DIR:?hydrate failed — check .env and yaml variables}"

echo "Run:     $RUN_NAME"
echo "YAML:    $YAML_PATH"
echo "Output:  $OUTPUT_DIR"
echo "Model:   $MODEL_NAME"
echo "Workers: $AGENT_WORKERS"
echo "Log:     tail -f $OUTPUT_DIR/minisweagent.log"
echo

if [[ "$CLEAN_START" == "1" ]]; then
  rm -f "$OUTPUT_DIR/preds.json"
  rm -rf "$OUTPUT_DIR/logs/run_evaluation"
fi

# Unbuffered Python so INFO lines appear in the terminal promptly.
export PYTHONUNBUFFERED=1

"${UV_RUN[@]}" mini-extra swebench \
  --subset "$SUBSET" \
  --split "$SPLIT" \
  --workers "$AGENT_WORKERS" \
  --output "$OUTPUT_DIR" \
  --model "$MODEL_NAME" \
  -c swebench.yaml \
  -c "$AGENT_CFG" \
  $SLICE_ARGS \
  $REDO_ARGS

echo
echo "Agent done. Predictions: $OUTPUT_DIR/preds.json"

if [[ "$RUN_EVAL" == "1" ]]; then
  "$MSR_ROOT/scripts/evaluate.sh" "$RUN_NAME"
fi
