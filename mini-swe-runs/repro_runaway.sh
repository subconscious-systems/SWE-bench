#!/usr/bin/env bash
# Re-run a single SWE-bench instance against the endpoint — quick repro driver
# for the runaway-generation bug. Always re-runs (ignores prior results) and
# writes to its own results dir so the main run's preds.json is untouched.
#
# Usage:
#   ./repro_runaway.sh                                  # default: astropy__astropy-14096
#   ./repro_runaway.sh astropy__astropy-14182           # any instance id
#   MAX_TOKENS=0 ./repro_runaway.sh                     # 0 = drop the cap (reproduce the full runaway)
#   TRACE=0 ./repro_runaway.sh                          # disable the request/response trace capture
#
# Traces land in traces/trace-<ts>.jsonl (one line per API call, live).
#
# Watch it live:  tail -f results/repro/<instance_id>/... appears as steps complete;
# the conversation is saved to results/repro/<instance_id>/<instance_id>.traj.json
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then set -a; source .env; set +a; fi
export OPENAI_API_KEY="${OPENAI_API_KEY:?set OPENAI_API_KEY in mini-swe-runs/.env}"
API_BASE="${API_BASE:-https://api.subconscious.dev/v1}"
MODEL="${MODEL:-openai/subconscious/tim-qwen3.6-27b}"
export LITELLM_MODEL_REGISTRY_PATH="$PWD/litellm_registry.json"
MSWEA_VERSION="${MSWEA_VERSION:-2.3.0}"

# Make turn_failure_model.py importable inside uvx's python
# (model.yaml selects it via model.model_class).
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"

# Retry budget for transient API errors (5xx/connection; timeouts never retry
# — see turn_failure_model.py). Upstream default is 10.
export MSWEA_MODEL_RETRY_STOP_AFTER_ATTEMPT="${MSWEA_MODEL_RETRY_STOP_AFTER_ATTEMPT:-5}"

INSTANCE="${1:-astropy__astropy-14096}"
OUTPUT_DIR="${OUTPUT_DIR:-results/repro}"

# Tracing (default ON; TRACE=0 disables): route the agent through a local
# logging proxy that captures every request/response body live to
# traces/trace-<ts>.jsonl — shareable while the run is still going; each line
# is replayable with curl. Auth headers are forwarded but never written to
# the trace. The proxy outlives the client timeout (1800s upstream), so even
# runaway responses the agent never saw get captured.
if [[ "${TRACE:-1}" == "1" ]]; then
  TRACE_PORT="${TRACE_PORT:-8788}"
  python3 trace_proxy.py --port "$TRACE_PORT" --upstream "${API_BASE%/v1}" &
  TRACE_PID=$!
  trap 'kill "$TRACE_PID" 2>/dev/null' EXIT
  sleep 1
  API_BASE="http://127.0.0.1:$TRACE_PORT/v1"
  echo ">>> tracing enabled: tail -f traces/trace-*.jsonl"
fi

# MAX_TOKENS=0 removes the cap so the raw runaway behavior is observable
# (request will then only die at the litellm timeout in model.yaml).
MAX_TOKENS="${MAX_TOKENS:-8192}"
EXTRA_ARGS=()
if [[ "$MAX_TOKENS" != "0" ]]; then
  EXTRA_ARGS+=(-c "model.model_kwargs.max_tokens=$MAX_TOKENS")
else
  echo ">>> max_tokens cap REMOVED for this repro (timeout in model.yaml still applies)"
fi

echo ">>> repro: $INSTANCE  (model=$MODEL, max_tokens=$MAX_TOKENS)"
uvx --from "mini-swe-agent==$MSWEA_VERSION" mini-extra swebench \
  --subset verified \
  --split test \
  --filter "^${INSTANCE}$" \
  --redo-existing \
  --workers 1 \
  --output "$OUTPUT_DIR" \
  --model "$MODEL" \
  -c swebench.yaml \
  -c model.yaml \
  -c "model.model_kwargs.api_base=$API_BASE" \
  "${EXTRA_ARGS[@]}"

echo
echo "Trajectory: $OUTPUT_DIR/$INSTANCE/$INSTANCE.traj.json"
