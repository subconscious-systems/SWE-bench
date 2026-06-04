#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

RUN_DIR="${1:-verified-full-v2}"
require_aws

remote_exec "cd '$MINI_SWE_RUNS_PATH' && RUN_DIR='$RUN_DIR' bash -s" <<'REMOTE'
set -euo pipefail
RESULTS="results/$RUN_DIR"
echo "=== Summary: $PWD/$RESULTS ==="
echo

if [[ -f "$RESULTS/preds.json" ]]; then
  n=$(python3 -c "import json; print(len(json.load(open('$RESULTS/preds.json'))))")
  echo "preds.json: $n completed"
else
  echo "preds.json: (missing)"
fi

REPORT="$(ls -t "$RESULTS"/*.*.json 2>/dev/null | head -1 || true)"
if [[ -n "$REPORT" && -f "$REPORT" ]]; then
  echo
  echo "--- Scorecard ---"
  uv run python - "$REPORT" <<'PY'
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
echo "preds.json:     $PWD/$RESULTS/preds.json"
echo "agent log:      $PWD/$RESULTS/minisweagent.log"
echo "exit statuses:  $PWD/$RESULTS/exit_statuses_*.yaml"
echo "eval report:    ${REPORT:-n/a}"

if [[ -x ./scripts/status.sh ]]; then
  echo
  echo "--- Recent (scripts/status.sh) ---"
  ./scripts/status.sh "$RESULTS" || true
fi
REMOTE
