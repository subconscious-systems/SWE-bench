#!/usr/bin/env bash
# Free disk by removing Docker images for completed instances in preds.json.
# Usage: ./scripts/prune_images.sh [results_dir]
set -euo pipefail
MSR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MSR_ROOT"

RESULTS_DIR="${1:-results/verified-full}"
PREDS="$RESULTS_DIR/preds.json"
[[ -f "$PREDS" ]] || { echo "no preds.json in $RESULTS_DIR — nothing to prune"; exit 0; }

removed=0
while IFS= read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || continue
  if docker rmi "$img" >/dev/null 2>&1; then
    removed=$((removed + 1))
  fi
done < <(python3 - "$PREDS" <<'EOF'
import json, sys
for iid in json.load(open(sys.argv[1])):
    print(f"swebench/sweb.eval.x86_64.{iid.replace('__', '_1776_')}:latest".lower())
EOF
)

docker image prune -f >/dev/null 2>&1 || true
echo "pruned $removed completed-instance image(s); disk now:"
docker system df | head -3
