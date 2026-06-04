# SWE-bench EC2 runner (SST)

Provision a dedicated **x86_64** EC2 host for [mini-swe-runs](../mini-swe-runs/) (SWE-bench Verified × mini-swe-agent), with **SSM/SSH** access, persistent disk, and optional **Cloudflare R2** archival.

Infrastructure is defined in [`sst.config.ts`](sst.config.ts) and [`infra/runner.ts`](infra/runner.ts) ([SST Ion v3](https://sst.dev/docs/)). Shell helpers live in [`infra/`](infra/) (provision, sync, destroy) and [`scripts/`](scripts/) (benchmark runs and results). Benchmark logic on the instance is in `mini-swe-runs/scripts/`.

## Prerequisites (laptop)

- Node.js 20+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- AWS SSO configured in `~/.aws/config` with permission to deploy EC2, IAM, EBS, `ssm:StartSession`, `ssm:SendCommand`, and `ec2-instance-connect:SendSSHPublicKey`
- Local SSH key (`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`) — used with EC2 Instance Connect for scp/rsync over SSM
- `rsync`, `ssh`, `scp`, `uv` (for local lockfile work)

```bash
aws sso login
```

Region defaults to **us-east-1** in all cloud scripts. Credentials come from the AWS CLI default chain after SSO login.

## Stages

Every cloud script takes **`<stage>`** as its first argument. One stage = one EC2 stack, tagged `swe-bench-runner-<stage>` (e.g. `qwen`, `kimi`). Use separate stages to run Qwen and Kimi benchmarks on independent hosts.

## Quick start

```bash
cd cloud
./infra/deploy.sh qwen          # SST deploy + wait for SSM
./infra/bootstrap.sh qwen       # Docker, uv, /data layout (idempotent)

cp ../mini-swe-runs/.env.example ../mini-swe-runs/.env   # QWEN_API_KEY, QWEN_BASE_URL, …
./infra/push-env.sh qwen
./infra/sync.sh qwen --install  # rsync repo + uv sync --frozen on EC2

./scripts/run.sh qwen yaml/qwen/smoke.yaml smoke-qwen
./scripts/run-tmux.sh qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1   # long jobs in tmux
./scripts/summary.sh qwen qwen-opt-v1
```

Kimi on a separate stack:

```bash
./infra/deploy.sh kimi
./infra/bootstrap.sh kimi
./infra/push-env.sh kimi
./infra/sync.sh kimi --install
./scripts/run-tmux.sh kimi yaml/kimi/verified-full.yaml kimi-june
```

Attach to a running tmux job:

```bash
./infra/ssh.sh qwen
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
| Region | `us-east-1` |

Override at deploy time:

```bash
INSTANCE_TYPE=m6i.4xlarge DATA_VOLUME_GB=400 ./infra/deploy.sh qwen
```

## Python toolchain (`mini-swe-runs`)

Pinned in [`../mini-swe-runs/pyproject.toml`](../mini-swe-runs/pyproject.toml) + `uv.lock`:

- `mini-swe-agent==2.3.0`
- `datacurve-pier` from GitHub (target tag **v2.1.0**; lock currently pins `main@830ed6b` until upstream publishes the tag — re-run `uv lock` after `v2.1.0` exists)
- `swebench`, `datasets`

Run scripts use `uv run` (not `uvx`). On the instance, `install-deps.sh` runs `uv sync --frozen`.

## Bootstrap

After `deploy.sh`, run [`./infra/bootstrap.sh`](infra/bootstrap.sh) `<stage>`. It runs [`user-data/bootstrap.sh`](user-data/bootstrap.sh) on the instance via SSM (Docker CE, uv, `/data` volume, `/opt/swe-bench` layout). Idempotent — safe to re-run.

Verifies:

- `docker info` works (root and `ubuntu` via `sg docker`)
- `uv` is installed
- `/opt/swe-bench` exists

Logs on the instance: `/var/log/swe-bench-bootstrap.log`

## Fresh deploy (destroy + recreate)

Each **stage** has its own EC2 instance (`swe-bench-runner-<stage>`) and data EBS volume (`swe-bench-runner-<stage>-data`, 300 GiB by default). Destroying `qwen` does not touch `kimi`.

Export results before destroy if you need them:

```bash
./scripts/pull-results.sh qwen my-run-name
./scripts/upload-results.sh qwen my-run-name   # zip → R2 (optional)
```

```bash
cd cloud
./infra/destroy.sh qwen          # sst remove — deletes stack AND data volume
./infra/deploy.sh qwen
./infra/bootstrap.sh qwen
./infra/push-env.sh qwen
./infra/sync.sh qwen --install
```

`destroy.sh` uses a **triple confirm** and warns that all `/data` is lost. There is no separate volume-delete script.

**Legacy volumes:** Stacks deployed before `retainOnDelete` was removed may leave an orphaned EBS volume after `sst remove`. Delete those once in the AWS console (tag `swe-bench-runner-<stage>-data`).

Pause compute but keep the same instance and all data:

```bash
./infra/stop.sh qwen           # no compute charge; ~$24/mo for volume still applies
./infra/start.sh qwen          # resume when needed
```

## Scripts

Infra: `./infra/<name>.sh <stage> [...]` — provision and operate the host.

| Script | Purpose |
|--------|---------|
| `deploy.sh` | `sst deploy` + wait for SSM |
| `bootstrap.sh` | Instance setup via SSM (Docker, uv, `/data`) — run after deploy |
| `destroy.sh` | `sst remove` — deletes stack **and** data EBS volume (destructive) |
| `stop.sh` / `start.sh` | Stop/start EC2 (instance + disk retained; no compute charge while stopped) |
| `push-env.sh` | Copy `mini-swe-runs/.env` to instance |
| `sync.sh` | Rsync repo → `/opt/swe-bench` (`--install` → `install-deps.sh`) |
| `install-deps.sh` | `uv sync --frozen` on EC2 |
| `ssh.sh` | Interactive shell as **ubuntu** via SSH over SSM (used by rsync/scp) |
| `connect.sh` | SSM shell as **ubuntu** (no SSH key; `sudo -iu ubuntu`) |

Benchmarks: `./scripts/<name>.sh <stage> [...]` — run SWE-bench on a deployed host.

Where a run is referenced, pass **`RUN_NAME`** only (same as the third arg to `run.sh`, e.g. `smoke-qwen`) — not `results/...`.

| Script | Purpose |
|--------|---------|
| `run.sh` | `<yaml-path> <RUN_NAME>` → remote `mini-swe-runs/scripts/run.sh` (foreground) |
| `run-tmux.sh` | Same args, detached tmux session (`TMUX_SESSION` overrides session name) |
| `prepull.sh` / `status.sh` / `evaluate.sh` | Remote `mini-swe-runs/scripts/*` |
| `summary.sh` | Remote `mini-swe-runs/scripts/summary.sh` (scorecard + status) |
| `pull-results.sh` | `[RUN_NAME]` → rsync artifacts to laptop |
| `upload-results.sh` | `[RUN_NAME]` → zip on EC2 → optional R2 upload |

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
./scripts/upload-results.sh qwen verified-full-v2
./scripts/upload-results.sh qwen verified-full-v2 --trajectories
./scripts/upload-results.sh qwen smoke --local   # from laptop
```

## Persistence

| Action | Data on `/data`? |
|--------|------------------|
| EC2 **stop** / **start** | Yes (same instance, volume attached) |
| `./infra/stop.sh <stage>` | Yes |
| `./infra/start.sh <stage>` | Yes — resumes the stopped instance |
| `./scripts/pull-results.sh` / `upload-results.sh` | Export copy (do before destroy) |
| `./infra/destroy.sh <stage>` | **No** — SST removes stack and data volume |

## Cost (us-east-1, on-demand)

- `m6i.2xlarge` ≈ **$0.38/hr** while running
- 300 GiB gp3 ≈ **~$24/mo** while volume exists (including while instance is stopped)
- `./infra/destroy.sh` stops volume billing by deleting the EBS volume

## Debugging

```bash
./infra/ssh.sh qwen
cd /opt/swe-bench/mini-swe-runs
./scripts/status.sh qwen-june
uv run pier --help

# Or from laptop:
./scripts/status.sh qwen smoke-qwen
./scripts/summary.sh qwen smoke-qwen
# Claude Code (install once on instance): curl -fsSL https://claude.ai/install.sh | bash
```

## SST only

```bash
cd cloud
export AWS_REGION=us-east-1
npx sst deploy --stage qwen
npx sst remove --stage qwen
```

`npx sst remove` deletes the data volume (same as `./infra/destroy.sh`). Non-`prod` stages use `removal: remove` in `sst.config.ts`; a `prod` stage retains the whole stack on remove.

Outputs include `instanceId`, `instancePublicIp`, `dataVolumeId`, `repoPath`, `miniSweRunsPath`.
