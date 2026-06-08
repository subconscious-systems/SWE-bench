#!/usr/bin/env bash
# One-line Slack progress/success text for an evaluation job (or a benchmark run
# that finished with RUN_EVAL=1). Prefers the harness score written by
# evaluate.sh; falls back to in-flight instance count.
#
# Usage: ./scripts/eval_notify_line.sh [RUN_NAME]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_run_name.sh
source "$SCRIPT_DIR/_run_name.sh"

msr_resolve_run_name "${1:-}"
SUMMARY_FILE="$RESULTS_DIR/eval_slack_summary.txt"

if [[ -f "$SUMMARY_FILE" ]]; then
  cat "$SUMMARY_FILE"
  exit 0
fi

n="$(find "$RESULTS_DIR/logs/run_evaluation" -name report.json 2>/dev/null | wc -l | tr -d ' ')"
echo "${n} instances scored"
