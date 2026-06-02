#!/usr/bin/env bash
# Full SWE-bench Verified run (500 instances) with mini-swe-agent against the
# Subconscious endpoint (subconscious/tim-qwen3.6-27b), then evaluation.
#
# Prereqs:
#   uv (https://docs.astral.sh/uv/) and Docker must be installed/running —
#   mini-swe-agent itself needs no install; uvx fetches it on first run.
#   Put your API key in mini-swe-runs/.env  (see .env.example)
#
# RESUME: automatic. Completed instances are recorded in $OUTPUT_DIR/preds.json
# and skipped on re-run — if the job dies or you Ctrl+C it, just run this
# script again and it picks up where it left off. (Evaluation resumes the same
# way: already-graded instances are skipped.)
set -euo pipefail
cd "$(dirname "$0")"

# Load secrets from .env (expects OPENAI_API_KEY=...)
if [[ -f .env ]]; then set -a; source .env; set +a; fi

export OPENAI_API_KEY="${OPENAI_API_KEY:?set OPENAI_API_KEY in mini-swe-runs/.env}"
API_BASE="${API_BASE:-https://api.subconscious.dev/v1}"
# openai/ prefix = litellm speaks the OpenAI chat completions protocol; the
# server receives "subconscious/tim-qwen3.6-27b" as the model field.
MODEL="${MODEL:-openai/subconscious/tim-qwen3.6-27b}"

# Pricing registry so litellm can compute per-task / total cost.
export LITELLM_MODEL_REGISTRY_PATH="$PWD/litellm_registry.json"

# Make turn_failure_model.py importable inside uvx's python
# (model.yaml selects it via model.model_class).
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"

# Retry budget for transient API errors (5xx/connection; timeouts never retry
# — see turn_failure_model.py). Upstream default is 10.
export MSWEA_MODEL_RETRY_STOP_AFTER_ATTEMPT="${MSWEA_MODEL_RETRY_STOP_AFTER_ATTEMPT:-5}"

OUTPUT_DIR="${OUTPUT_DIR:-results/verified-full-v2}"

# Agent parallelism = concurrent requests against the API (each worker has at
# most one request in flight). Keep at 4 to stay within the endpoint's
# concurrency limits — raise deliberately, not for speed.
AGENT_WORKERS="${AGENT_WORKERS:-4}"

# Eval parallelism is local-only (test containers, no API traffic) — safe to
# raise independently on a beefy box. Consumed by evaluate.sh as WORKERS.
export WORKERS="${EVAL_WORKERS:-8}"

# Pinned for reproducibility — bump deliberately.
MSWEA_VERSION="${MSWEA_VERSION:-2.3.0}"

# Phase 1: run the agent on all instances.
uvx --from "mini-swe-agent==$MSWEA_VERSION" mini-extra swebench \
  --subset verified \
  --split test \
  --workers "$AGENT_WORKERS" \
  --output "$OUTPUT_DIR" \
  --model "$MODEL" \
  -c swebench.yaml \
  -c model.yaml \
  -c "model.model_kwargs.api_base=$API_BASE"

echo
echo "Agent run done. Predictions: $OUTPUT_DIR/preds.json  (trajectories in $OUTPUT_DIR/<instance_id>/)"

# Phase 2: grade everything and print the scorecard.
./evaluate.sh "$OUTPUT_DIR"
