#!/usr/bin/env bash
# On-demand wall-clock report for a run: per-trace agent time, whole-job time,
# and per-instance eval test runtime (if evaluation has run). Read-only —
# gathers everything from the timestamped minisweagent.log and eval logs.
#
# Usage:  ./timings.sh [results_dir]      (default: results/verified-full)
set -euo pipefail
cd "$(dirname "$0")"

RESULTS_DIR="${1:-results/verified-full}"
[[ -f "$RESULTS_DIR/minisweagent.log" ]] || { echo "error: no minisweagent.log in $RESULTS_DIR" >&2; exit 1; }

python3 - "$RESULTS_DIR" <<'EOF'
import re, sys, statistics
from datetime import datetime
from pathlib import Path

results = Path(sys.argv[1])
TS = "%Y-%m-%d %H:%M:%S,%f"
ts_re = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3}) - ")
start_re = re.compile(r"Starting container with command:.*sweb\.eval\.[^.]+\.(\S+):")
end_ok_re = re.compile(r"Saved trajectory to '.*/([^/]+)\.traj\.json'")
end_err_re = re.compile(r"Error processing instance (\S+?):")

# Collect per-instance event streams: (time, kind) with kind in start/ok/err.
events, all_ts = {}, []
for line in (results / "minisweagent.log").read_text().splitlines():
    m_ts = ts_re.match(line)
    if not m_ts:
        continue
    t = datetime.strptime(m_ts.group(1), TS)
    all_ts.append(t)
    if m := start_re.search(line):
        events.setdefault(m.group(1).replace("_1776_", "__"), []).append((t, "start"))
    elif m := end_ok_re.search(line):
        events.setdefault(m.group(1), []).append((t, "ok"))
    elif m := end_err_re.search(line):
        events.setdefault(m.group(1), []).append((t, "err"))

# Pair each start with the end that follows it (resumed/redone instances have
# several attempts). Report the last attempt that finished; note a trailing
# unfinished attempt if one exists.
rows = []
for iid, evs in events.items():
    attempts, open_start = [], None
    for t, kind in sorted(evs):
        if kind == "start":
            open_start = t
        elif open_start is not None:
            attempts.append((open_start, t, "done" if kind == "ok" else "error"))
            open_start = None
    status_extra = " (+ newer unfinished attempt)" if open_start is not None else ""
    if attempts:
        s, e, status = attempts[-1]
        rows.append((iid, (e - s).total_seconds(), status + status_extra))
    else:
        rows.append((iid, None, "unfinished (running or killed)"))

print(f"\n## Agent wall-clock — {results}\n")
print("| Instance | Wall time | Status |")
print("|---|---|---|")
done = []
for iid, secs, status in sorted(rows, key=lambda r: r[1] or -1, reverse=True):
    if secs is not None:
        if status.startswith("done"):
            done.append(secs)
        print(f"| {iid} | {int(secs//60)}m{int(secs%60):02d}s | {status} |")
    else:
        print(f"| {iid} | — | {status} |")

if done:
    print(f"\ntraces: {len(done)} timed | median {statistics.median(done):.0f}s | "
          f"mean {statistics.mean(done):.0f}s | max {max(done):.0f}s")
    print("(per-trace time includes image pull on first use; "
          "traces run in parallel, so they sum to more than the job wall time)")
if all_ts:
    job = (max(all_ts) - min(all_ts)).total_seconds()
    print(f"whole agent job (first to last log line, incl. resumed sessions): "
          f"{int(job//3600)}h{int(job%3600//60):02d}m{int(job%60):02d}s")

# Eval timing, if evaluation has run.
eval_runtimes = {}
for log in results.glob("logs/run_evaluation/*/*/*/run_instance.log"):
    if m := re.search(r"Test runtime: ([\d.]+) seconds", log.read_text()):
        eval_runtimes[log.parent.name] = float(m.group(1))
if eval_runtimes:
    total = sum(eval_runtimes.values())
    print(f"\n## Eval test runtime — {len(eval_runtimes)} instance(s), "
          f"median {statistics.median(eval_runtimes.values()):.0f}s, "
          f"total {int(total//60)}m{int(total%60):02d}s (split across workers)")
    for iid, secs in sorted(eval_runtimes.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  {iid}: {secs:.0f}s")
EOF
