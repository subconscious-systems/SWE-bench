#!/usr/bin/env bash
# Shared RUN_NAME resolution for mini-swe-runs scripts. Source only; do not execute.
# Sets RUN_NAME, RESULTS_DIR (absolute). MSR_ROOT is fixed at source time.

_MSR_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSR_ROOT="$(cd "$_MSR_SCRIPTS_DIR/.." && pwd)"

msr_resolve_run_name() {
  local raw="${1:-${MSR_RUN_NAME_DEFAULT:-verified-full-v2}}"
  if [[ -z "$raw" || "$raw" == */* ]]; then
    echo "error: pass RUN_NAME only (e.g. smoke-qwen), not a path" >&2
    exit 1
  fi
  RUN_NAME="$raw"
  RESULTS_DIR="$MSR_ROOT/results/$RUN_NAME"
}

msr_require_results_dir() {
  [[ -d "$RESULTS_DIR" ]] || {
    echo "error: no results directory: $RESULTS_DIR" >&2
    exit 1
  }
}
