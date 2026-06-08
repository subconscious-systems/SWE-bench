#!/usr/bin/env bash
# Wrap a long-running job with Slack notifications: start, periodic progress,
# and a terminal success/failure (with a log tail on failure). Runs on the
# instance; invoked by swb for run/evaluate/prepull.
#
# Usage:
#   run_job.sh <job> <run_name> [--progress '<cmd that echoes one line>'] \
#              [--interval <secs>] -- <command...>
#
# The job's stage comes from $SWB_STAGE (set by swb) or /opt/swe-bench/.swb-stage.
# Slack is best-effort and never changes the job's own exit code.
set -uo pipefail

NOTIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify.sh"

JOB="${1:-}"
RUN_NAME="${2:-}"
if [[ -z "$JOB" || -z "$RUN_NAME" ]]; then
  echo "usage: run_job.sh <job> <run_name> [--progress CMD] [--interval N] -- <command...>" >&2
  exit 2
fi
shift 2

PROGRESS_CMD=""
INTERVAL="${SLACK_NOTIFY_INTERVAL_SECS:-1800}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --progress) PROGRESS_CMD="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "run_job.sh: unexpected arg before --: $1" >&2; exit 2 ;;
  esac
done
if [[ $# -eq 0 ]]; then
  echo "run_job.sh: no command given after --" >&2
  exit 2
fi

notify() { "$NOTIFY" "$@" >/dev/null 2>&1 || true; }

fmt_dur() {
  local s="$1"
  printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

START_EPOCH="$(date +%s)"
# Stable, tailable log (not a throwaway temp file). Prefer the run's results
# dir so the log travels with results; fall back to a predictable /tmp path.
LOG="${TMPDIR:-/tmp}/swb-job-${RUN_NAME}.log"
[[ -d "results/$RUN_NAME" ]] && LOG="results/$RUN_NAME/run_job.log"
: > "$LOG"
echo "run_job: live log -> $LOG  (tail -f, or attach the tmux session)"

notify start "$JOB" "$RUN_NAME" "started"

# Run the job, streaming output to BOTH the log and our stdout (so the tmux
# pane / foreground show it live) while a progress loop watches the PID.
"$@" > >(tee "$LOG") 2>&1 &
job_pid=$!

prog_pid=""
if [[ -n "$PROGRESS_CMD" && "$INTERVAL" -gt 0 ]]; then
  (
    while kill -0 "$job_pid" 2>/dev/null; do
      sleep "$INTERVAL" || break
      kill -0 "$job_pid" 2>/dev/null || break
      line="$(eval "$PROGRESS_CMD" 2>/dev/null | tail -1)"
      [[ -n "$line" ]] && notify progress "$JOB" "$RUN_NAME" "$line"
    done
  ) &
  prog_pid=$!
fi

wait "$job_pid"
rc=$?

[[ -n "$prog_pid" ]] && { kill "$prog_pid" 2>/dev/null || true; wait "$prog_pid" 2>/dev/null || true; }

dur="$(fmt_dur $(( $(date +%s) - START_EPOCH )))"

if [[ "$rc" -eq 0 ]]; then
  final="$(eval "$PROGRESS_CMD" 2>/dev/null | tail -1)"
  notify success "$JOB" "$RUN_NAME" "SUCCESS · ${final:-done} · ${dur}"
else
  # Strip CRs so a Rich/live console's last frame is readable in Slack.
  tail_lines="$(tr '\r' '\n' < "$LOG" 2>/dev/null | tail -n 15)"
  notify failure "$JOB" "$RUN_NAME" "FAILED · exit ${rc} · ${dur}"$'\n'"\`\`\`${tail_lines}\`\`\`"
fi

# Output already streamed via tee above; just preserve the job's exit code.
exit "$rc"
