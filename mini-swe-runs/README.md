# SWE-bench Verified × mini-swe-agent × Subconscious

Run [SWE-bench Verified](https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified) (500 instances)
against the Subconscious endpoint (`subconscious/tim-qwen3.6-27b`) using the
[mini-swe-agent](https://mini-swe-agent.com) harness.

## Prerequisites

- [uv](https://docs.astral.sh/uv/) — the scripts run mini-swe-agent via `uvx`, no install needed
- Docker, running — each instance executes in its own container
- A Subconscious API key

> **Note on hardware:** the per-instance images are `x86_64`. On Apple Silicon they run
> emulated (slow). Fine for the smoke test; prefer a Linux x86 box for the full run.
> Images add up to a few hundred GB if all are kept — `docker system prune` between batches.

## Setup

```bash
cd mini-swe-runs
cp .env.example .env     # then paste your API key into .env
```

`.env` is gitignored — keys never get committed.

## 1. Smoke test (run this first)

Runs 2 instances end-to-end to verify the endpoint, config, and Docker setup:

```bash
./run_smoke.sh
```

Success looks like: `results/smoke/preds.json` exists and each entry has a non-empty
`model_patch`. Per-instance cost in the progress display should be small but **non-zero** —
$0.00 means the pricing registry isn't being picked up.

## 2. Full run

```bash
./run_full.sh
```

- 500 instances, 4 parallel workers
- Output: `results/verified-full/preds.json` (+ a trajectory dir per instance)
- Expect this to take many hours; run it in tmux/screen or with `nohup`

## Restarting / resuming

**Resume is automatic.** Completed instances are recorded in `preds.json` and skipped on
re-run. If the job dies, the machine reboots, or you Ctrl+C — just run the same script
again and it continues where it left off.

- Granularity is per-instance: anything mid-trajectory when killed restarts from scratch
- One Ctrl+C = graceful (in-flight instances finish, pending ones cancel); twice = immediate
- Force a full redo of everything: add `--redo-existing` to the `mini-extra` command
- Redo specific instances: delete their entries from `preds.json` (or delete `preds.json`
  for all) and re-run

## Configuration

| What | Where |
|---|---|
| Model, base URL, API key | env vars / `.env` (defaults baked into scripts) |
| Iterations per task (`step_limit: 250`), cost limit (disabled) | `model.yaml` |
| Token pricing ($0.50/M in, $0.05/M cached in, $3.50/M out) | `litellm_registry.json` |
| Parallelism, dataset, output dir | flags in the scripts (`--workers`, `--subset`, `-o`) |
| mini-swe-agent version (pinned: 2.3.0) | `MSWEA_VERSION` env var |

Handy one-off overrides (append to the `mini-extra` command):

```bash
-c agent.step_limit=50              # shorter runs while debugging
--filter 'django__django-11[0-9]+'  # only matching instance IDs
--slice '0:25'                      # first 25 instances
```

If the endpoint ever rejects requests due to tool-call params, set
`parallel_tool_calls: false` in `model.yaml`; if the model lacks tool-calling entirely,
swap `-c swebench.yaml` for `-c swebench_backticks.yaml` in the scripts.

## Scoring the run

```bash
./evaluate.sh                  # scores results/verified-full
./evaluate.sh results/smoke    # scores the smoke run
```

This runs the official SWE-bench evaluation harness (needs Docker — it replays each
patch in its instance container and runs the tests), then prints a copy-pasteable
markdown scorecard:

```
| Metric | Value |
|---|---|
| **Score (resolved / benchmark)** | **N/500 (XX.X%)** |
| ...
```

The "Score" line is the leaderboard-comparable number (% Resolved). The full report
json (with `resolved_ids`, `unresolved_ids`, etc. for digging into specific instances)
is written next to `preds.json`. Works on partial runs too — it only evaluates
what's in `preds.json` and shows a separate resolved/submitted line.

Alternative without local Docker: [sb-cli](https://github.com/SWE-bench/sb-cli)
evaluates in the cloud — `sb-cli submit swe-bench_verified test --predictions_path
results/verified-full/preds.json --run_id verified-full`.

## Debugging a bad instance

Every step the agent took is in
`results/<run>/<instance_id>/<instance_id>.traj.json` — the full conversation,
commands, and outputs. Exit statuses across the run are summarized in
`results/<run>/exit_statuses_*.yaml`.
