#!/usr/bin/env bash
# Full SWE-bench Verified run (500 instances) with mini-swe-agent against the
# Subconscious endpoint (subconscious/tim-qwen3.6-27b).
#
# Prereqs:
#   uv (https://docs.astral.sh/uv/) and Docker must be installed/running —
#   mini-swe-agent itself needs no install; uvx fetches it on first run.
#   Put your API key in mini-swe-runs/.env  (see .env.example)
#
# RESUME: this is automatic. Completed instances are recorded in
# $OUTPUT_DIR/preds.json and skipped on re-run — so if the job dies or you
# Ctrl+C it, just run this script again with the same OUTPUT_DIR and it picks
# up where it left off (granularity is per-instance: an instance that was
# mid-trajectory when killed restarts from scratch).
# To force a full redo instead, add: --redo-existing
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

OUTPUT_DIR="${OUTPUT_DIR:-results/verified-full}"
mkdir -p "$OUTPUT_DIR"

# Shared by the agent run (--workers) and the evaluation harness
# (--max_workers). Note both phases overlap when EVAL_EVERY > 0, so peak
# load is up to 2x this many containers.
export WORKERS="${WORKERS:-4}"

# Pinned for reproducibility — bump deliberately.
MSWEA_VERSION="${MSWEA_VERSION:-2.3.0}"

# One trap cleans up all background loops on any exit (incl. Ctrl+C).
BG_PIDS=()
cleanup() { for pid in "${BG_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

# OPT-IN evaluate-as-you-go: EVAL_EVERY=900 ./run_full.sh grades whatever new
# instances have landed in preds.json every 900s (the harness is incremental
# per run_id — graded instances are skipped; concurrent invocations serialize
# on a lock). Saves the post-run eval wait (~3-6h) but doubles container load,
# and on a resource-constrained box eval containers can starve agent
# containers (60s command timeout) and hurt the score — leave off unless the
# machine has headroom. Default 0 = evaluate serially after the run.
# Don't combine with PRUNE_EVERY — pruning deletes images the evaluator needs.
EVAL_EVERY="${EVAL_EVERY:-0}"
EVAL_LOOP_PID=""
if (( EVAL_EVERY > 0 )); then
  (
    while sleep "$EVAL_EVERY"; do
      ./evaluate.sh "$OUTPUT_DIR" >> "$OUTPUT_DIR/eval_during_run.log" 2>&1 || true
    done
  ) &
  EVAL_LOOP_PID=$!
  BG_PIDS+=("$EVAL_LOOP_PID")
  echo "parallel evaluation enabled: grading new results every ${EVAL_EVERY}s (log: $OUTPUT_DIR/eval_during_run.log)"
fi

# Optional disk reaper: PRUNE_EVERY=600 ./run_full.sh removes the Docker image
# of each completed instance every 600s (only instances already in preds.json
# are touched, so this never races the in-flight workers). Leave at 0 if the
# box has ~300GB+ free — you'll want the images again for local evaluation.
PRUNE_EVERY="${PRUNE_EVERY:-0}"
if (( PRUNE_EVERY > 0 )); then
  (
    while sleep "$PRUNE_EVERY"; do
      ./prune_images.sh "$OUTPUT_DIR" || true
    done
  ) &
  BG_PIDS+=("$!")
  echo "image reaper enabled: pruning completed-instance images every ${PRUNE_EVERY}s"
fi

uvx --from "mini-swe-agent==$MSWEA_VERSION" mini-extra swebench \
  --subset verified \
  --split test \
  --workers "$WORKERS" \
  --output "$OUTPUT_DIR" \
  --model "$MODEL" \
  -c swebench.yaml \
  -c model.yaml \
  -c "model.model_kwargs.api_base=$API_BASE"

echo
echo "Done. Predictions: $OUTPUT_DIR/preds.json  (trajectories in $OUTPUT_DIR/<instance_id>/)"

# Stop spawning new watcher cycles; an in-flight one finishes and the final
# pass below waits on the eval lock, then grades only the remaining tail.
[[ -n "$EVAL_LOOP_PID" ]] && kill "$EVAL_LOOP_PID" 2>/dev/null || true

# Auto-score the run unless disabled with AUTO_EVAL=0.
if [[ "${AUTO_EVAL:-1}" == "1" ]]; then
  ./evaluate.sh "$OUTPUT_DIR"
else
  echo "Skipped auto-eval (AUTO_EVAL=0). Score later with:  ./evaluate.sh $OUTPUT_DIR"
fi
