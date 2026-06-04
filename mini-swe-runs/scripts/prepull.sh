#!/usr/bin/env bash
# Pre-pull instance images before a run.
# Usage: ./scripts/prepull.sh [N]   (0 = all 500)
set -euo pipefail
MSR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MSR_ROOT"

N="${1:-0}"

uv run --python 3.12 python - "$N" <<'EOF' | xargs -P 2 -n 1 docker pull
import sys
from datasets import load_dataset

ds = list(load_dataset("princeton-nlp/SWE-bench_Verified", split="test"))
n = int(sys.argv[1]) or len(ds)
for inst in ds[:n]:
    iid = inst["instance_id"].replace("__", "_1776_")
    print(f"swebench/sweb.eval.x86_64.{iid}:latest".lower())
EOF

echo "done; local image usage:"
docker system df | head -3
