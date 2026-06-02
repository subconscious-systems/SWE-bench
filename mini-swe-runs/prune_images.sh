#!/usr/bin/env bash
# Free disk by removing Docker images for instances that have already
# completed (i.e., are recorded in preds.json).
#
# Safe to run while the agent is running:
#  - in-flight instances aren't in preds.json yet, so their images are never
#    touched (each instance uses its own dedicated image, used exactly once)
#  - `docker rmi` without -f refuses to remove an image whose container still
#    exists; we skip errors and catch stragglers on the next sweep
#
# Usage:  ./prune_images.sh [results_dir]      (default: results/verified-full)
# Or let run_full.sh drive it:  PRUNE_EVERY=600 ./run_full.sh
set -euo pipefail
cd "$(dirname "$0")"

RESULTS_DIR="${1:-results/verified-full}"
PREDS="$RESULTS_DIR/preds.json"
[[ -f "$PREDS" ]] || { echo "no preds.json in $RESULTS_DIR — nothing to prune"; exit 0; }

removed=0
while IFS= read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || continue   # not present locally
  if docker rmi "$img" >/dev/null 2>&1; then
    removed=$((removed + 1))
  fi
done < <(python3 - "$PREDS" <<'EOF'
import json, sys
for iid in json.load(open(sys.argv[1])):
    print(f"swebench/sweb.eval.x86_64.{iid.replace('__', '_1776_')}:latest".lower())
EOF
)

docker image prune -f >/dev/null 2>&1 || true   # clear now-dangling layers
echo "pruned $removed completed-instance image(s); disk now:"
docker system df | head -3
