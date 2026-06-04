#!/usr/bin/env bash
# Read-only scorecard + status for a run.
# Usage: ./scripts/summary.sh [RUN_NAME]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_run_name.sh
source "$SCRIPT_DIR/_run_name.sh"

msr_resolve_run_name "${1:-}"
msr_require_results_dir
cd "$RESULTS_DIR"

echo "=== Summary: $RESULTS_DIR ==="
echo

if [[ -f preds.json ]]; then
  n=$(python3 -c "import json; print(len(json.load(open('preds.json'))))")
  echo "preds.json: $n completed"
else
  echo "preds.json: (missing)"
fi

REPORT="$(ls -t ./*.*.json 2>/dev/null | head -1 || true)"
if [[ -n "$REPORT" && -f "$REPORT" ]]; then
  echo
  echo "--- Scorecard ---"
  uv run --project "$MSR_ROOT" python - "$REPORT" <<'PY'
import json, sys
path = sys.argv[1]
r = json.load(open(path))
total = r["total_instances"]
sub = r["submitted_instances"]
res = r["resolved_instances"]
label = __import__("os").environ.get("MODEL_LABEL", "subconscious/tim-qwen3.6-27b")
print(f"## SWE-bench Verified — {label}")
print()
print("| Metric | Value |")
print("|---|---|")
print(f"| **Score (resolved / benchmark)** | **{res}/{total} ({100*res/total:.1f}%)** |")
if sub != total:
    print(f"| Resolved / submitted (partial run) | {res}/{sub} ({100*res/sub:.1f}%) |")
print(f"| Submitted | {sub} |")
print(f"| Completed | {r['completed_instances']} |")
print(f"| Unresolved | {r['unresolved_instances']} |")
print(f"| Empty patch | {r['empty_patch_instances']} |")
print(f"| Eval errors | {r['error_instances']} |")
print()
print(f"Report: {path}")
PY
else
  echo "(no eval report json yet)"
fi

echo
echo "--- Paths ---"
echo "preds.json:     $RESULTS_DIR/preds.json"
echo "agent log:      $RESULTS_DIR/minisweagent.log"
echo "exit statuses:  $RESULTS_DIR/exit_statuses_*.yaml"
echo "eval report:    ${REPORT:-n/a}"

echo
echo "--- Recent (scripts/status.sh) ---"
"$SCRIPT_DIR/status.sh" "$RUN_NAME" || true
