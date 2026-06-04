#!/usr/bin/env bash
# Evaluate a finished (or partial) run with the official SWE-bench harness and
# print a shareable scorecard.
#
# Usage:
#   ./scripts/evaluate.sh [RUN_NAME] [run_id]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_run_name.sh
source "$SCRIPT_DIR/_run_name.sh"

msr_resolve_run_name "${1:-verified-full}"
RUN_ID="${2:-$RUN_NAME}"
cd "$MSR_ROOT"

ulimit -n 65536 2>/dev/null || echo "warn: could not raise fd limit (ulimit -n = $(ulimit -n))" >&2

WORKERS="${WORKERS:-4}"
PREDS_JSON="$RESULTS_DIR/preds.json"

[[ -f "$PREDS_JSON" ]] || { echo "error: no preds.json at $PREDS_JSON" >&2; exit 1; }

# Harness writes the summary JSON and logs/run_evaluation/ relative to process cwd
# (swebench --report_dir only mkdirs; it does not relocate the summary file).
# Run from RESULTS_DIR so artifacts stay under results/<RUN_NAME>/.
(
  cd "$RESULTS_DIR"
  uv run --project "$MSR_ROOT" --python 3.12 python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Verified --split test \
    --predictions_path preds.json \
    --max_workers "$WORKERS" \
    --clean "${CLEAN:-False}" \
    --run_id "$RUN_ID"
)

REPORT="$(ls -t "$RESULTS_DIR"/*."$RUN_ID".json 2>/dev/null | head -1)"
[[ -n "$REPORT" ]] || { echo "error: report json not found in $RESULTS_DIR" >&2; exit 1; }

uv run --directory "$MSR_ROOT" --python 3.12 python - "$REPORT" <<'EOF'
import json, sys

path = sys.argv[1]
r = json.load(open(path))
total = r["total_instances"]
sub = r["submitted_instances"]
res = r["resolved_instances"]

label = __import__("os").environ.get("MODEL_LABEL", "subconscious/tim-qwen3.6-27b")
print()
print(f"## SWE-bench Verified — {label}")
print()
print("| Metric | Value |")
print("|---|---|")
print(f"| **Score (resolved / benchmark)** | **{res}/{total} ({100*res/total:.1f}%)** |")
if sub != total:
    print(f"| Resolved / submitted (partial run) | {res}/{sub} ({100*res/sub:.1f}%) |")
print(f"| Submitted | {sub} |")
print(f"| Completed (ran to a verdict) | {r['completed_instances']} |")
print(f"| Unresolved | {r['unresolved_instances']} |")
print(f"| Empty patch | {r['empty_patch_instances']} |")
print(f"| Eval errors | {r['error_instances']} |")
print()
print(f"Full per-instance breakdown (resolved_ids / unresolved_ids / ...): {path}")
EOF
