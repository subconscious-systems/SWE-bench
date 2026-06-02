#!/usr/bin/env bash
# Smoke test: run just 2 SWE-bench Verified instances end-to-end to verify the
# Subconscious endpoint, config, and Docker setup before the full run.
set -euo pipefail
cd "$(dirname "$0")"

# Load secrets from .env (expects OPENAI_API_KEY=...)
if [[ -f .env ]]; then set -a; source .env; set +a; fi

export OPENAI_API_KEY="${OPENAI_API_KEY:?set OPENAI_API_KEY in mini-swe-runs/.env}"
API_BASE="${API_BASE:-https://api.subconscious.dev/v1}"
MODEL="${MODEL:-openai/subconscious/tim-qwen3.6-27b}"

# Pricing registry so litellm can compute per-task / total cost.
export LITELLM_MODEL_REGISTRY_PATH="$PWD/litellm_registry.json"

OUTPUT_DIR="${OUTPUT_DIR:-results/smoke}"

# Smoke runs are scratch — start with a clean slate so stale entries from
# earlier attempts don't pollute the scorecard. This includes the eval ledger:
# the harness skips instances with an existing grading report for the same
# run_id, which would silently report the PREVIOUS patch's verdict.
rm -f "$OUTPUT_DIR/preds.json"
rm -rf "$OUTPUT_DIR/logs/run_evaluation"

# Pinned for reproducibility — bump deliberately.
MSWEA_VERSION="${MSWEA_VERSION:-2.3.0}"

uvx --from "mini-swe-agent==$MSWEA_VERSION" mini-extra swebench \
  --subset verified \
  --split test \
  --slice '0:1' \
  --workers 2 \
  --output "$OUTPUT_DIR" \
  --model "$MODEL" \
  -c swebench.yaml \
  -c model.yaml \
  -c "model.model_kwargs.api_base=$API_BASE" \
  --redo-existing

# Tips:
#  - To pick specific instances instead of the first two, swap --slice for a
#    regex filter, e.g.:  --filter 'astropy__astropy-1313[89]'
#  - Inspect what the agent did:  $OUTPUT_DIR/<instance_id>/<instance_id>.traj.json
#  - Lower the step ceiling for faster iteration while debugging:
#    add  -c agent.step_limit=50

echo
echo "Smoke run finished — grading the patch(es) with the official harness..."
./evaluate.sh "$OUTPUT_DIR"
