#!/usr/bin/env bash
# Pre-pull instance images so slow downloads happen before a run (e.g.
# overnight) instead of during it. Layers are shared across images, so total
# download for all 500 Verified instances is ~50-80GB, not 500 x 1.1GB.
#
# Usage:
#   ./prepull.sh        # all 500 Verified images
#   ./prepull.sh 25     # first 25 (matches --slice '0:25' ordering)
#
# Safe to interrupt and re-run: already-pulled layers are skipped.
set -euo pipefail
cd "$(dirname "$0")"

N="${1:-0}"   # 0 = all

uv run --no-project --with datasets python - "$N" <<'EOF' | xargs -P 2 -n 1 docker pull
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
