#!/usr/bin/env bash
# Re-run a single instance for runaway-generation debugging (separate results dir).
#
# Usage:
#   ./scripts/repro_runaway.sh [instance_id]
#   ./scripts/repro_runaway.sh -f yaml/qwen/smoke.yaml astropy__astropy-14182
#   MAX_TOKENS=0 ./scripts/repro_runaway.sh
#   TRACE=0 ./scripts/repro_runaway.sh
set -euo pipefail

MSR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MSR_ROOT"

HYDRATE="uv run python scripts/hydrate_run_yaml.py"
YAML_PATH="${YAML_PATH:-yaml/qwen/smoke.yaml}"
INSTANCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--config)
      YAML_PATH="$2"
      shift 2
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
    *)
      INSTANCE="$1"
      shift
      ;;
  esac
done
INSTANCE="${INSTANCE:-astropy__astropy-14096}"
OUTPUT_DIR="${OUTPUT_DIR:-results/repro}"

CACHE_DIR="$MSR_ROOT/.run-cache/repro-$$"
AGENT_CFG="$CACHE_DIR/agent.yaml"
mkdir -p "$CACHE_DIR"
trap 'rm -rf "$CACHE_DIR"' EXIT

eval "$($HYDRATE --shell "$YAML_PATH")"
$HYDRATE --agent-config "$AGENT_CFG" "$YAML_PATH" >/dev/null

META_JSON="$($HYDRATE --meta-json "$YAML_PATH")"
MODEL_NAME="$(echo "$META_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['model_name'])")"
API_BASE="$(uv run python -c "import yaml; print(yaml.safe_load(open('$AGENT_CFG'))['model']['model_kwargs']['api_base'])")"

if [[ "${TRACE:-1}" == "1" ]]; then
  TRACE_PORT="${TRACE_PORT:-8788}"
  python3 "$MSR_ROOT/trace_proxy.py" --port "$TRACE_PORT" --upstream "${API_BASE%/v1}" &
  TRACE_PID=$!
  trap 'kill "$TRACE_PID" 2>/dev/null; rm -rf "$CACHE_DIR"' EXIT
  sleep 1
  API_BASE="http://127.0.0.1:$TRACE_PORT/v1"
  echo ">>> tracing enabled: tail -f traces/trace-*.jsonl"
fi

MAX_TOKENS="${MAX_TOKENS:-8192}"
MAX_TOKENS_C=""
MAX_TOKENS_OVERRIDE=""
if [[ "$MAX_TOKENS" != "0" ]]; then
  MAX_TOKENS_C=-c
  MAX_TOKENS_OVERRIDE="model.model_kwargs.max_tokens=$MAX_TOKENS"
else
  echo ">>> max_tokens cap REMOVED for this repro"
fi

echo ">>> repro: $INSTANCE  (model=$MODEL_NAME, max_tokens=$MAX_TOKENS, yaml=$YAML_PATH)"
uv run mini-extra swebench \
  --subset verified \
  --split test \
  --filter "^${INSTANCE}$" \
  --redo-existing \
  --workers 1 \
  --output "$OUTPUT_DIR" \
  --model "$MODEL_NAME" \
  -c swebench.yaml \
  -c "$AGENT_CFG" \
  -c "model.model_kwargs.api_base=$API_BASE" \
  ${MAX_TOKENS_C:+$MAX_TOKENS_C "$MAX_TOKENS_OVERRIDE"}

echo
echo "Trajectory: $OUTPUT_DIR/$INSTANCE/$INSTANCE.traj.json"
