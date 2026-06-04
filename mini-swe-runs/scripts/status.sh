#!/usr/bin/env bash
# Read-only status snapshot of an in-progress run.
# Usage: ./scripts/status.sh [RUN_NAME] [resume_epoch]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_run_name.sh
source "$SCRIPT_DIR/_run_name.sh"

msr_resolve_run_name "${1:-}"
SINCE="${2:-$(date -v-3H +%s 2>/dev/null || date -d '3 hours ago' +%s)}"
msr_require_results_dir
cd "$RESULTS_DIR"

echo "=== $(date '+%H:%M:%S')  results/$RUN_NAME ==="
python3 - "$SINCE" << 'EOF'
import json, glob, os, sys, datetime as dt, statistics as st

since = float(sys.argv[1])
preds = json.load(open('preds.json'))
print(f"preds.json: {len(preds)} completed total")

recent = [f for f in glob.glob('*/*.traj.json') if os.path.getmtime(f) > since]
recent.sort(key=os.path.getmtime)
if recent:
    print(f"\nfinished since {dt.datetime.fromtimestamp(since):%H:%M}:")
    print(f"  {'instance':28} {'exit':14} {'calls':>5} {'s/call':>6} {'stalls>120s':>11} {'patch'}")
for f in recent:
    t = json.load(open(f))
    info = t.get('info', {})
    created = sorted(r['created'] for m in t.get('messages', [])
                     if (r := (m.get('extra') or {}).get('response')))
    gaps = [b - a for a, b in zip(created, created[1:])]
    calls = len(created)
    dur = created[-1] - created[0] if calls > 1 else 0
    spc = dur / calls if calls else 0
    stalls = sum(1 for g in gaps if g > 120)
    patch = 'yes' if (info.get('submission') or '').strip() else 'EMPTY'
    print(f"  {f.split('/')[0]:28} {str(info.get('exit_status')):14} {calls:5d} {spc:6.1f} {stalls:11d} {patch}")

if recent:
    t = json.load(open(recent[-1]))
    created = sorted(r['created'] for m in t.get('messages', [])
                     if (r := (m.get('extra') or {}).get('response')))
    gaps = [b - a for a, b in zip(created, created[1:])][-20:]
    if gaps:
        print(f"\nlast-20-turn gaps of newest finish: med={st.median(gaps):.0f}s max={max(gaps):.0f}s")
EOF

echo
echo "in-flight containers (current command, '-' = idle/thinking):"
docker ps --filter name=minisweagent- --format '{{.Names}}\t{{.Image}}' | while IFS=$'\t' read -r name img; do
  inst="${img##*_1776_}"; inst="${inst%%:*}"
  up=$(docker ps --filter "name=$name" --format '{{.RunningFor}}')
  cmd=$(docker top "$name" -o command 2>/dev/null | tail -n +2 | grep -v 'sleep 2h' | head -1 | cut -c1-80 || true)
  printf '  %-22s %-22s up %-14s %s\n' "$name" "$inst" "$up" "${cmd:--}"
done
