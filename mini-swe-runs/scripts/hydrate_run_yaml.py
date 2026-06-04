#!/usr/bin/env python3
"""Load a run-spec YAML, expand ${VAR}, emit shell exports or agent config for mini-swe-agent."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any

import yaml
from dotenv import dotenv_values

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")

# scripts/hydrate_run_yaml.py → mini-swe-runs/
MSR_ROOT = Path(__file__).resolve().parents[1]
AGENT_KEYS = ("agent", "model", "environment")


def _load_dotenv(msr_root: Path) -> dict[str, str]:
    env_path = msr_root / ".env"
    raw = dotenv_values(env_path) if env_path.is_file() else {}
    ctx: dict[str, str] = {k: str(v) for k, v in os.environ.items()}
    for k, v in raw.items():
        if v is not None:
            ctx[k] = str(v)
    ctx["MSR_ROOT"] = str(msr_root)
    return ctx


def _expand_string(s: str, ctx: dict[str, str]) -> str:
    def repl(m: re.Match[str]) -> str:
        name = m.group(1)
        if name not in ctx:
            raise KeyError(f"undefined variable ${{{name}}} in run spec (set in .env?)")
        return ctx[name]

    return VAR_RE.sub(repl, s)


def _expand_value(val: Any, ctx: dict[str, str]) -> Any:
    if isinstance(val, str):
        return _expand_string(val, ctx)
    if isinstance(val, dict):
        return {k: _expand_value(v, ctx) for k, v in val.items()}
    if isinstance(val, list):
        return [_expand_value(v, ctx) for v in val]
    return val


def load_run_spec(yaml_path: Path, msr_root: Path | None = None) -> dict[str, Any]:
    root = msr_root or MSR_ROOT
    spec_path = yaml_path if yaml_path.is_absolute() else root / yaml_path
    if not spec_path.is_file():
        raise FileNotFoundError(spec_path)

    raw = yaml.safe_load(spec_path.read_text()) or {}
    dotenv = _load_dotenv(root)

    env_block = raw.get("env") or {}
    ctx = {**dotenv}
    for k, v in env_block.items():
        ctx[k] = _expand_string(str(v), {**dotenv, **ctx})

    expanded_env = {k: ctx[k] for k in env_block}

    agent_cfg = {}
    for key in AGENT_KEYS:
        if key in raw:
            agent_cfg[key] = _expand_value(raw[key], ctx)

    return {
        "meta": raw.get("meta") or {},
        "benchmark": raw.get("benchmark") or {},
        "env": expanded_env,
        "agent_config": agent_cfg,
        "source": str(spec_path),
    }


def _shell_export(key: str, value: str) -> str:
    return f"export {key}={shlex.quote(str(value))}"


def emit_bootstrap(loaded: dict[str, Any], run_name: str, msr_root: Path) -> None:
    """Print shell assignments for eval in run.sh (env, paths, mini-extra flags)."""
    meta = loaded["meta"]
    bench = loaded["benchmark"]
    cache_dir = msr_root / ".run-cache" / run_name
    agent_cfg = cache_dir / "agent.yaml"
    cache_dir.mkdir(parents=True, exist_ok=True)
    agent_cfg.write_text(
        yaml.safe_dump(loaded["agent_config"], default_flow_style=False, sort_keys=False)
    )

    for k, v in loaded["env"].items():
        print(_shell_export(k, v))

    # Relative to MSR_ROOT so mini-extra and evaluate.sh behave under uv --directory.
    output_dir = f"results/{run_name}"
    slice_val = bench.get("smoke_slice") or bench.get("slice") or ""
    slice_args = f"--slice {slice_val}" if slice_val else ""
    redo_args = "--redo-existing" if bench.get("redo_existing") else ""

    print(_shell_export("MODEL_NAME", meta["model_name"]))
    print(_shell_export("MODEL_LABEL", meta.get("model_label", meta["model_name"])))
    print(_shell_export("AGENT_WORKERS", meta.get("agent_workers", 4)))
    print(_shell_export("WORKERS", meta.get("eval_workers", 4)))
    print(_shell_export("SUBSET", bench.get("subset", "verified")))
    print(_shell_export("SPLIT", bench.get("split", "test")))
    print(_shell_export("OUTPUT_DIR", str(output_dir)))
    print(_shell_export("AGENT_CFG", str(agent_cfg)))
    print(_shell_export("CLEAN_START", "1" if bench.get("clean_start") else "0"))
    print(_shell_export("RUN_EVAL", "1" if bench.get("run_eval", True) else "0"))
    print(f"SLICE_ARGS={shlex.quote(slice_args)}")
    print(f"REDO_ARGS={shlex.quote(redo_args)}")


def main() -> int:
    p = argparse.ArgumentParser(description="Hydrate mini-swe-runs run-spec YAML")
    p.add_argument("yaml_path", type=Path, help="Path to run-spec yaml")
    p.add_argument("--msr-root", type=Path, default=MSR_ROOT)
    p.add_argument("--shell", action="store_true", help="Print export statements for eval")
    p.add_argument("--agent-config", type=Path, metavar="PATH", help="Write expanded agent yaml")
    p.add_argument("--meta-json", action="store_true", help="Print meta+benchmark as JSON")
    p.add_argument(
        "--bootstrap",
        metavar="RUN_NAME",
        help="Write agent yaml + print all shell vars for scripts/run.sh",
    )
    args = p.parse_args()

    try:
        loaded = load_run_spec(args.yaml_path, args.msr_root)
    except (FileNotFoundError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.bootstrap:
        emit_bootstrap(loaded, args.bootstrap, args.msr_root)

    if args.shell:
        for k, v in loaded["env"].items():
            print(_shell_export(k, v))

    if args.agent_config:
        args.agent_config.parent.mkdir(parents=True, exist_ok=True)
        args.agent_config.write_text(
            yaml.safe_dump(loaded["agent_config"], default_flow_style=False, sort_keys=False)
        )

    if args.meta_json:
        out = {**loaded["meta"], "benchmark": loaded["benchmark"], "source": loaded["source"]}
        print(json.dumps(out))

    if not (args.shell or args.agent_config or args.meta_json or args.bootstrap):
        p.print_help()
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
