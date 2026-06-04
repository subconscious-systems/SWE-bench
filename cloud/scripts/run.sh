#!/usr/bin/env bash
# Run a benchmark on EC2 (foreground). Same interface as mini-swe-runs/scripts/run.sh.
#
# Usage: ./scripts/run.sh <yaml-path> <RUN_NAME>
#
# Examples:
#   ./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
#   ./scripts/run.sh yaml/qwen/optimized-v1.yaml qwen-opt-v1
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"
require_aws

YAML_PATH="${1:-}"
RUN_NAME="${2:-}"

[[ -n "$YAML_PATH" && -n "$RUN_NAME" ]] || {
  echo "usage: $0 <yaml-path> <RUN_NAME>" >&2
  exit 1
}

run_cmd="./scripts/run.sh $(printf '%q' "$YAML_PATH") $(printf '%q' "$RUN_NAME")"
echo "Remote: cd $MINI_SWE_RUNS_PATH && $run_cmd"
echo "Log on instance: tail -f $MINI_SWE_RUNS_PATH/results/$RUN_NAME/minisweagent.log"
echo

remote_exec "cd '$MINI_SWE_RUNS_PATH' && bash -lc $(printf '%q' "$run_cmd")"
