# SWE-bench Verified × mini-swe-agent × Subconscious

Run [SWE-bench Verified](https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified) (500 instances)
against the Subconscious endpoint using the [mini-swe-agent](https://mini-swe-agent.com) harness.

## Prerequisites

- [uv](https://docs.astral.sh/uv/) — scripts use `uv run` with a pinned lockfile
- Docker, running — each instance executes in its own container
- API keys in `.env` (see `.env.example`)

> **Note on hardware:** instance images are `x86_64`. On Apple Silicon they run emulated (slow).
> Use a Linux x86 box for the full run.

## Setup

```bash
cd mini-swe-runs
cp .env.example .env     # QWEN_API_KEY, QWEN_BASE_URL, KIMI_* placeholders
uv sync --frozen
```

`.env` is gitignored. Run specs live under `yaml/` — see [`yaml/README.md`](yaml/README.md).

## Smoke test

```bash
./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
./scripts/run.sh yaml/kimi/smoke.yaml smoke-kimi
```

Success: `results/smoke-qwen/preds.json` with non-empty `model_patch` entries.

## Full run

```bash
./scripts/run.sh yaml/qwen/verified-full.yaml qwen-june
./scripts/run.sh yaml/kimi/verified-full.yaml kimi-june
```

- 500 instances, 4 workers (from yaml `meta` / `benchmark`)
- Output: `results/<RUN_NAME>/`
- **Resume:** same yaml path + `RUN_NAME`
- **Variants:** copy/edit files under `yaml/qwen/` or `yaml/kimi/`

Optional root shim: `./run.sh` → `scripts/run.sh`.

Agent progress is mostly in `results/<RUN_NAME>/minisweagent.log` (not every step on stdout):

```bash
tail -f results/smoke-qwen/minisweagent.log
```

Set `benchmark.run_eval: false` in a yaml to skip the harness after the agent.

## EC2 (cloud)

From [`../cloud/`](../cloud/):

```bash
./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
./scripts/run-tmux.sh yaml/qwen/optimized-v1.yaml qwen-opt-v1
```

## Resuming

Completed instances are in `preds.json` and skipped on re-run. Smoke yamls set `clean_start: true`
(wipes preds on each smoke invocation). For a full run, re-run the same command after interrupt.

## Disk / images

```bash
./scripts/prepull.sh        # all 500 images
./scripts/prepull.sh 25     # first 25
./scripts/prune_images.sh results/qwen-june
```

`CLEAN=True ./scripts/evaluate.sh results/qwen-june qwen-june` — eval with container cleanup.

## Configuration

| What | Where |
|------|--------|
| Run name | second arg → `results/<RUN_NAME>/` |
| Full run definition | `yaml/qwen/*.yaml`, `yaml/kimi/*.yaml` |
| Secrets | `.env` (`QWEN_*`, `KIMI_*`) |
| Agent/model limits | `agent` / `model` in run-spec yaml |
| Token pricing | `litellm_registry.json` |

Hydration (`scripts/hydrate_run_yaml.py`) expands `${VAR}` in yaml from `.env` and writes
`.run-cache/<RUN_NAME>/agent.yaml` for mini-swe-agent.

## Scoring

Eval runs automatically after the agent when `benchmark.run_eval` is true (default). Manual:

```bash
MODEL_LABEL=subconscious/tim-qwen3.6-27b ./scripts/evaluate.sh results/qwen-june qwen-june
```

## Other scripts

| Script | Purpose |
|--------|---------|
| `scripts/status.sh` | In-progress snapshot |
| `scripts/timings.sh` | Wall-clock report |
| `scripts/repro_runaway.sh` | Single-instance repro with trace proxy |
