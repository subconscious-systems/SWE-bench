#!/usr/bin/env bash
# Evaluate a finished (or partial) run with the official SWE-bench harness and
# print a shareable scorecard.
#
# Usage:
#   ./evaluate.sh                          # evaluates results/verified-full
#   ./evaluate.sh results/smoke            # evaluate the smoke run
#   ./evaluate.sh results/verified-full myrun-v2   # custom run_id
#
# Needs Docker (the harness replays each patch in the instance's container and
# runs the tests). Safe to re-run; also fine on partial runs — it only
# evaluates instances present in preds.json.
set -euo pipefail
cd "$(dirname "$0")"

RESULTS_DIR="${1:-results/verified-full}"
RUN_ID="${2:-$(basename "$RESULTS_DIR")}"
WORKERS="${WORKERS:-4}"

[[ -f "$RESULTS_DIR/preds.json" ]] || { echo "error: no preds.json in $RESULTS_DIR" >&2; exit 1; }

# Run from inside the results dir so the report json and logs/ land next to
# the predictions instead of polluting the repo root.
(
  cd "$RESULTS_DIR"
  # --clean True: evaluation is the last consumer of each instance image, so
  # the harness deletes each one right after grading it (cache_level defaults
  # to "env", which keeps the shared base/env layers for future runs).
  # Set CLEAN=False to keep all images, e.g. when re-running evals repeatedly.
  uv run --no-project --with swebench python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Verified --split test \
    --predictions_path preds.json \
    --max_workers "$WORKERS" \
    --clean "${CLEAN:-True}" \
    --run_id "$RUN_ID"
)

REPORT="$(ls -t "$RESULTS_DIR"/*."$RUN_ID".json 2>/dev/null | head -1)"
[[ -n "$REPORT" ]] || { echo "error: report json not found in $RESULTS_DIR" >&2; exit 1; }

python3 - "$REPORT" <<'EOF'
import json, sys

path = sys.argv[1]
r = json.load(open(path))
total = r["total_instances"]          # full benchmark (500 for Verified)
sub = r["submitted_instances"]        # instances in preds.json
res = r["resolved_instances"]

print()
print("## SWE-bench Verified — subconscious/tim-qwen3.6-27b")
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
