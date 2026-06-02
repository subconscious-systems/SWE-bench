#!/usr/bin/env bash
# Re-run a single SWE-bench instance against the endpoint — quick repro driver
# for the runaway-generation bug. Always re-runs (ignores prior results) and
# writes to its own results dir so the main run's preds.json is untouched.
#
# Usage:
#   ./repro_runaway.sh                                  # default: astropy__astropy-14096
#   ./repro_runaway.sh astropy__astropy-14182           # any instance id
#   MAX_TOKENS=0 ./repro_runaway.sh                     # 0 = drop the cap (reproduce the full runaway)
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

INSTANCE="${1:-astropy__astropy-14096}"
OUTPUT_DIR="${OUTPUT_DIR:-results/repro}"

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
