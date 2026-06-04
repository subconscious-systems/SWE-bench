# Run-spec YAML files

Each file is a **complete benchmark definition**: environment exports, mini-swe-agent config, and harness flags. Run with:

```bash
./scripts/run.sh <yaml-path> <RUN_NAME>
```

Examples:

```bash
./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
./scripts/run.sh yaml/qwen/verified-full.yaml qwen-june
./scripts/run.sh yaml/kimi/verified-full.yaml kimi-june
```

Re-run the **same** yaml + `RUN_NAME` to resume (`results/<RUN_NAME>/preds.json`).

## Schema

| Section | Passed to mini-swe-agent? | Purpose |
|---------|---------------------------|---------|
| `meta` | No | `model_name`, `model_label`, `agent_workers`, `eval_workers` |
| `env` | No (exported to shell) | `${VAR}` expanded from `.env` + `MSR_ROOT` |
| `benchmark` | No | `subset`, `split`, `smoke_slice`, `clean_start`, `redo_existing`, `run_eval` (default true) |
| `agent`, `model`, `environment` | Yes | Standard mini-swe-agent YAML |

## `.env` variables

| Variable | Used by |
|----------|---------|
| `QWEN_API_KEY`, `QWEN_BASE_URL` | `yaml/qwen/*.yaml` |
| `KIMI_API_KEY`, `KIMI_BASE_URL` | `yaml/kimi/*.yaml` → `OPENAI_BASE_URL` + `model.model_kwargs.api_base` (use `http://kimi.subconscious.dev/v1`, not https) |

## Adding a variant

Copy e.g. `yaml/qwen/verified-full.yaml` → `yaml/qwen/my-tweak.yaml`, edit `agent` / `model` / `meta`, then:

```bash
./scripts/run.sh yaml/qwen/my-tweak.yaml my-run-name
```
