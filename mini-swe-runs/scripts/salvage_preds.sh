#!/usr/bin/env bash
# Rebuild preds.json from per-instance *.traj.json files (e.g. after disk-full corruption).
# Skips if preds.json already exists in the run directory.
#
# Usage: ./scripts/salvage_preds.sh [RUN_NAME]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_run_name.sh
source "$SCRIPT_DIR/_run_name.sh"

msr_resolve_run_name "${1:-}"
msr_require_results_dir

PREDS="$RESULTS_DIR/preds.json"
if [[ -f "$PREDS" ]]; then
  echo "preds.json already exists: $PREDS"
  echo "remove or rename it first if you need to salvage from trajectories"
  exit 0
fi

cd "$RESULTS_DIR"
uv run --project "$MSR_ROOT" python - <<'PY'
import json
import sys
from pathlib import Path

results = Path(".")
trajs = sorted(results.glob("*/*.traj.json"))
if not trajs:
    print("error: no */*.traj.json files under", results.resolve(), file=sys.stderr)
    sys.exit(1)

preds = {}
empty = 0
for traj in trajs:
    instance_id = traj.parent.name
    data = json.loads(traj.read_text())
    info = data.get("info") or {}
    model = (
        (info.get("config") or {})
        .get("model", {})
        .get("model_name", "unknown")
    )
    patch = info.get("submission") or ""
    if not str(patch).strip():
        empty += 1
    preds[instance_id] = {
        "model_name_or_path": model,
        "model_patch": patch,
    }

out = results / "preds.json"
out.write_text(json.dumps(preds, indent=2) + "\n")
print(f"wrote {len(preds)} entries -> {out}")
if empty:
    print(f"  ({empty} with empty model_patch)")
PY
