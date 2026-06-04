# SWE-bench EC2 runner (SST)

Provision a dedicated **x86_64** EC2 host for [mini-swe-runs](../mini-swe-runs/) (SWE-bench Verified × mini-swe-agent), with **SSM/SSH** access, persistent disk, and optional **Cloudflare R2** archival.

Infrastructure is defined in [`sst.config.ts`](sst.config.ts) ([SST Ion v3](https://sst.dev/docs/)). The benchmark scripts themselves live in `mini-swe-runs/` and are synced to the instance unchanged.

## Prerequisites (laptop)

- Node.js 20+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- AWS SSO profile with permission to deploy EC2, IAM, EBS, and `ssm:StartSession`
- `rsync`, `ssh`, `scp`, `uv` (for local lockfile work)

```bash
export AWS_PROFILE=your-sso-profile
export AWS_REGION=us-east-1
aws sso login --profile "$AWS_PROFILE"
```

## Quick start

```bash
cd cloud
./scripts/deploy.sh              # SST deploy → m6i.2xlarge + 300GB data volume

cp ../mini-swe-runs/.env.example ../mini-swe-runs/.env   # QWEN_API_KEY, QWEN_BASE_URL, …
./scripts/push-env.sh
./scripts/sync.sh --install      # rsync repo + uv sync --frozen on EC2

./scripts/run.sh yaml/qwen/smoke.yaml smoke-qwen
./scripts/run-tmux.sh yaml/qwen/optimized-v1.yaml qwen-opt-v1   # long jobs in tmux
# Parallel: TMUX_SESSION=swebench-kimi ./scripts/run-tmux.sh yaml/kimi/verified-full.yaml kimi-june
./scripts/summary.sh qwen-opt-v1
```

Attach to a running tmux job:

```bash
./scripts/ssh.sh
tmux attach -t swebench-qwen-opt-v1   # or your TMUX_SESSION / RUN_NAME
tail -f /opt/swe-bench/mini-swe-runs/results/<RUN_NAME>/minisweagent.log
```

## Instance defaults

| Setting | Default |
|---------|---------|
| Type | `m6i.2xlarge` (8 vCPU, 32 GiB) |
| Data volume | 300 GiB gp3 on `/data` |
| AMI | Ubuntu 24.04 amd64 (Python 3.12) |
| Repo on instance | `/opt/swe-bench` |

Override at deploy time:

```bash
INSTANCE_TYPE=m6i.4xlarge DATA_VOLUME_GB=400 ./scripts/deploy.sh
```

## Python toolchain (`mini-swe-runs`)

Pinned in [`../mini-swe-runs/pyproject.toml`](../mini-swe-runs/pyproject.toml) + `uv.lock`:

- `mini-swe-agent==2.3.0`
- `datacurve-pier` from GitHub (target tag **v2.1.0**; lock currently pins `main@830ed6b` until upstream publishes the tag — re-run `uv lock` after `v2.1.0` exists)
- `swebench`, `datasets`

Run scripts use `uv run` (not `uvx`). On the instance, `install-deps.sh` runs `uv sync --frozen`.

## Scripts

| Script | Purpose |
|--------|---------|
| `deploy.sh` | `sst deploy` + wait for SSM |
| `destroy.sh` | `sst remove` (data volume is **protected**) |
| `stop.sh` / `start.sh` | Stop/start EC2 (disk retained) |
| `push-env.sh` | Copy `mini-swe-runs/.env` to instance |
| `sync.sh` | Rsync repo → `/opt/swe-bench` (`--install` → `install-deps.sh`) |
| `install-deps.sh` | `uv sync --frozen` on EC2 |
| `ssh.sh` | Interactive shell (SSM SSH proxy) |
| `connect.sh` | SSM session (no SSH) |
| `run.sh` | `<yaml-path> <RUN_NAME>` → remote `mini-swe-runs/scripts/run.sh` (foreground) |
| `run-tmux.sh` | Same args, detached tmux session (`TMUX_SESSION` overrides session name) |
| `prepull.sh` / `status.sh` / `evaluate.sh` | Remote `mini-swe-runs/scripts/*` |
| `summary.sh` | Scorecard + progress on instance |
| `pull-results.sh` | Rsync artifacts to laptop |
| `upload-results.sh` | Zip on EC2 → optional R2 upload |

Stage name defaults to `dev`: `STAGE=prod ./scripts/deploy.sh`

## Secrets (`.env`)

Required for runs: `QWEN_API_KEY`, `QWEN_BASE_URL` (and `KIMI_*` for kimi yamls).

Optional for R2 upload (bucket created **out of band** in Cloudflare — not SST):

```bash
R2_ACCOUNT_ID=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_BUCKET=
R2_PREFIX=swe-bench-runs
# R2_ENDPOINT=           # default: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
# R2_PUBLIC_BASE_URL=    # optional printed URL
```

```bash
./scripts/upload-results.sh verified-full-v2
./scripts/upload-results.sh verified-full-v2 --trajectories
./scripts/upload-results.sh smoke --local   # from laptop
```

## Persistence

| Action | Data on `/data`? |
|--------|------------------|
| EC2 **stop** / **start** | Yes |
| `./scripts/stop.sh` | Yes |
| Instance **terminate** | Data volume usually survives (`deleteOnTermination: false` on attach) |
| `destroy.sh` | EBS volume **protected** — may remain in AWS; clean up manually if needed |

## Cost (us-east-1, on-demand)

- `m6i.2xlarge` ≈ **$0.38/hr** while running
- 300 GiB gp3 ≈ **~$24/mo** while volume exists (even if instance stopped)

## Debugging

```bash
./scripts/ssh.sh
cd /opt/swe-bench/mini-swe-runs
./scripts/status.sh results/qwen-june
uv run pier --help
# Claude Code (install once on instance): curl -fsSL https://claude.ai/install.sh | bash
```

## SST only

```bash
cd cloud
npx sst deploy --stage dev
npx sst remove --stage dev
```

Outputs include `instanceId`, `instancePublicIp`, `dataVolumeId`, `repoPath`, `miniSweRunsPath`.
