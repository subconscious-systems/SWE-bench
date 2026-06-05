# SWE-bench Verified × mini-swe-agent × Subconscious

Run [SWE-bench Verified](https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified) (500 instances)
against the Subconscious endpoint using the [mini-swe-agent](https://mini-swe-agent.com) harness.

## Prerequisites

- [uv](https://docs.astral.sh/uv/) — installs and runs **Python 3.12** via uv (not pyenv/system shims)
- Docker, running — each instance executes in its own container
- API keys in `.env` (see `.env.example`)

> **Note on hardware:** instance images are `x86_64`. On Apple Silicon they run emulated (slow).
> Use a Linux x86 box for the full run.

## Setup

Python is **uv-managed** (`python-preference = only-managed` in `pyproject.toml`). Do not rely on pyenv for this project.

```bash
cd mini-swe-runs
cp .env.example .env     # QWEN_*, KIMI_*, SPARK_* placeholders
uv python install 3.12   # once per machine (uv downloads a full CPython with lzma, ssl, …)
uv sync --frozen         # creates .venv from uv.lock + .python-version
uv run python -c "import lzma; print('ok')"   # sanity check
```

If you previously used pyenv here, remove the old venv first: `rm -rf .venv && uv sync --frozen`.

`.env` is gitignored. Run specs live under `yaml/` — see [`yaml/README.md`](yaml/README.md).

## Smoke test

```bash
./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
./scripts/run.sh yaml/qwen/spark-smoke.yaml smoke-spark
./scripts/run.sh yaml/kimi/smoke.yaml smoke-kimi
```

Success: `results/smoke-qwen/preds.json` with non-empty `model_patch` entries.

## Full run

```bash
./scripts/run.sh yaml/qwen/verified-full.yaml qwen-june
./scripts/run.sh yaml/qwen/spark-8bit-v1.yaml spark-8bit-v1-june
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

From [`../cloud/`](../cloud/) (see [`cloud/README.md`](../cloud/README.md) for full setup):

```bash
./infra/deploy.sh qwen
./infra/bootstrap.sh qwen
./infra/push-env.sh qwen
./infra/sync.sh qwen --install
./scripts/run.sh qwen yaml/qwen/smoke.yaml smoke-qwen
./scripts/prepull.sh qwen              # before full Verified runs
./scripts/run-tmux.sh qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1
```

## Resuming

Completed instances are in `preds.json` and skipped on re-run. Smoke yamls set `clean_start: true`
(wipes preds on each smoke invocation). For a full run, re-run the same command after interrupt.

On EC2, archive and restore the full `results/<RUN_NAME>/` tree via R2 (see [`cloud/README.md`](../cloud/README.md)):

```bash
./scripts/upload-results.sh <stage> <RUN_NAME>    # zip mirror → R2
./scripts/restore-results.sh <stage> <RUN_NAME>   # R2 → results/<RUN_NAME>/ (fresh instance)
```

## Disk / images

On EC2, bootstrap stores image layers under **`/data/containerd`** (containerd snapshotter), not `/var/lib/docker`. Plan for **~300GB** on `/data` for a full 500-image cache; the default data volume is **500GB** (~200GB left for results/logs). `prepull.sh` inspects which images are already local and only requires proportional free space (scaled from the 300GB budget), with a **100GB minimum** for running the benchmark. Use `./scripts/docker_storage.sh` to confirm layout and headroom before long runs.

**Pre-pull before a full run** (on-demand pulls during the agent run can fill the wrong disk or hit Hub rate limits):

```bash
./scripts/docker_storage.sh           # layout + free space report
./scripts/prepull.sh                  # all 500 images (headroom scales with missing images; min 100G)
./scripts/prepull.sh 25                 # first 25 (smoke / test)
./scripts/prune_images.sh qwen-june     # drop images for completed instances
```

Optional: `docker login` before prepull for higher Docker Hub rate limits.

`CLEAN=True ./scripts/evaluate.sh qwen-june` — eval with container cleanup.

## Configuration

| What | Where |
|------|--------|
| Run name | second arg → `results/<RUN_NAME>/` |
| Full run definition | `yaml/qwen/*.yaml`, `yaml/kimi/*.yaml` |
| Secrets | `.env` (`QWEN_*`, `KIMI_*`, `SPARK_*`) |
| Agent/model limits | `agent` / `model` in run-spec yaml |
| Token pricing | `litellm_registry.json` |

Hydration (`scripts/hydrate_run_yaml.py`) expands `${VAR}` in yaml from `.env` and writes
`.run-cache/<RUN_NAME>/agent.yaml` for mini-swe-agent.

## Scoring

Eval runs automatically after the agent when `benchmark.run_eval` is true (default). Manual:

```bash
MODEL_LABEL=subconscious/tim-qwen3.6-27b ./scripts/evaluate.sh qwen-june
```

Optional second arg to `evaluate.sh`: harness `run_id` (defaults to `RUN_NAME`).

## Other scripts

Scripts that take a run use **`RUN_NAME`** only (e.g. `smoke-qwen`), not `results/...`.

| Script | Purpose |
|--------|---------|
| `scripts/summary.sh` | Scorecard + paths + recent status |
| `scripts/status.sh` | In-progress snapshot |
| `scripts/timings.sh` | Wall-clock report |
| `scripts/docker_storage.sh` | Containerd/Docker paths and disk headroom |
| `scripts/prepull.sh` | Pre-pull eval images (pre-flight storage check) |
| `scripts/prune_images.sh` | Drop Docker images for completed instances |
| `scripts/repro_runaway.sh` | Single-instance repro with trace proxy |
