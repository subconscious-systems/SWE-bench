#!/usr/bin/env bash
# Start a benchmark on EC2 in tmux (detached). Same args as run.sh.
#
# Usage: ./scripts/run-tmux.sh <stage> <yaml-path> <RUN_NAME>
#
# Examples:
#   ./scripts/run-tmux.sh qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1
#   TMUX_SESSION=swebench-qwen-opt ./scripts/run-tmux.sh qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1
set -euo pipefail
# shellcheck source=../infra/_common.sh
source "$(dirname "$0")/../infra/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws

YAML_PATH="${1:-}"
RUN_NAME="${2:-}"

[[ -n "$YAML_PATH" && -n "$RUN_NAME" ]] || {
  echo "usage: $0 <stage> <yaml-path> <RUN_NAME>" >&2
  exit 1
}

SESSION="${TMUX_SESSION:-swebench-$RUN_NAME}"
run_cmd="./scripts/run.sh $(printf '%q' "$YAML_PATH") $(printf '%q' "$RUN_NAME")"
# Keep tmux alive after run.sh exits so attach + scrollback still work.
tmux_cmd="cd '$MINI_SWE_RUNS_PATH' && $run_cmd; exec bash"

remote_exec "cd '$MINI_SWE_RUNS_PATH' && \
  (tmux has-session -t '$SESSION' 2>/dev/null && tmux kill-session -t '$SESSION' || true) && \
  tmux new-session -d -s '$SESSION' bash -lc $(printf '%q' "$tmux_cmd") && \
  echo Started: $run_cmd && \
  echo 'tmux session:' '$SESSION' && \
  echo 'Log: tail -f' '$MINI_SWE_RUNS_PATH/results/$RUN_NAME/minisweagent.log' && \
  echo 'Attach: ./infra/ssh.sh' '$STAGE' '# tmux attach -t' '$SESSION'"
