#!/usr/bin/env bash
# Pre-pull instance images before a run.
# Usage: ./scripts/prepull.sh [N]   (0 = all 500)
#
# Headroom on /data is computed from how many images are still missing locally
# (300G budget spread over 500 images), with a 100G floor for running the benchmark.
#
# Optional: docker login for higher Hub rate limits before pulling.
set -euo pipefail
MSR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MSR_ROOT"

N="${1:-0}"
MIN_RUN_HEADROOM_GB=100
FULL_CACHE_BUDGET_GB=300
VERIFIED_INSTANCES=500

PREPULL_LIST="$(mktemp)"
trap 'rm -f "$PREPULL_LIST"' EXIT

read -r TARGET REMAINING HEADROOM_G <<< "$(uv run python - \
  "$N" "$PREPULL_LIST" "$MIN_RUN_HEADROOM_GB" "$FULL_CACHE_BUDGET_GB" "$VERIFIED_INSTANCES" <<'PY'
import math
import subprocess
import sys
from datasets import load_dataset

n_arg = int(sys.argv[1])
out_path = sys.argv[2]
min_run_gb = int(sys.argv[3])
full_cache_gb = int(sys.argv[4])
verified_n = int(sys.argv[5])

ds = list(load_dataset("princeton-nlp/SWE-bench_Verified", split="test"))
n = n_arg or len(ds)
refs = []
for inst in ds[:n]:
    iid = inst["instance_id"].replace("__", "_1776_")
    refs.append(f"swebench/sweb.eval.x86_64.{iid}:latest".lower())

missing_refs = []
for ref in refs:
    if subprocess.run(["docker", "image", "inspect", ref], capture_output=True).returncode != 0:
        missing_refs.append(ref)

with open(out_path, "w") as f:
    for ref in missing_refs:
        f.write(ref + "\n")

remaining = len(missing_refs)
target = len(refs)
per_image_gb = full_cache_gb / verified_n
headroom_g = max(min_run_gb, math.ceil(remaining * per_image_gb))
print(target, remaining, headroom_g)
PY
)"

LOCAL=$((TARGET - REMAINING))
echo "prepull: $LOCAL/$TARGET images present, $REMAINING to pull → require ${HEADROOM_G}G free on /data (min ${MIN_RUN_HEADROOM_GB}G)"

"$MSR_ROOT/scripts/docker_storage.sh" --quiet --require-headroom "${HEADROOM_G}G"

if [[ "$REMAINING" -eq 0 ]]; then
  echo "all $TARGET images already present; skipping pull"
  "$MSR_ROOT/scripts/docker_storage.sh"
  exit 0
fi

xargs -P 2 -n 1 docker pull < "$PREPULL_LIST"

echo "done; images pulled: $(docker images -q | wc -l | tr -d ' ')"
"$MSR_ROOT/scripts/docker_storage.sh"
