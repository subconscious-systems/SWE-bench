# SWE-bench EC2 runner (SST)

Provision a dedicated **x86_64** EC2 host for [mini-swe-runs](../mini-swe-runs/) (SWE-bench Verified × mini-swe-agent), with **SSM/SSH** access, persistent disk, a **golden EBS snapshot** so new instances start with all ~500 eval images already present, and optional **Cloudflare R2** archival.

Everything is driven by one CLI: [`./swb`](swb).

```
cloud/
  swb               # the CLI (run `./swb help`)
  infra/runner.ts   # SST/Pulumi resources (EC2, EBS, IAM)
  lib/              # laptop-side helpers (stage/AWS, SSH-over-SSM transport, SSM, R2)
  remote/           # scripts that run ON the instance (bootstrap, ready, results)
```

## Prerequisites (laptop)

- Node.js 20+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- AWS SSO configured in `~/.aws/config` with permission to deploy EC2, IAM, EBS, `ssm:StartSession`, `ssm:SendCommand`, and `ec2-instance-connect:SendSSHPublicKey`
- Local SSH key (`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`) — used with EC2 Instance Connect over SSM
- `git`, `ssh`

```bash
aws sso login
```

Region defaults to **us-east-1**.

## Stages

Every command takes **`<stage>`** as its first argument after the command name. One stage = one EC2 stack, tagged `swe-bench-runner-<stage>` (e.g. `qwen`, `kimi`). Use separate stages to run Qwen and Kimi benchmarks on independent hosts.

## Quick start

```bash
cd cloud
./swb deploy qwen               # SST deploy + wait for SSM (uses golden snapshot if cloud/.snapshot-id exists)
./swb bootstrap qwen            # Docker on /data, uv, deploy repo (idempotent)

git commit ...                  # sync deploys COMMITTED code (see "Code sync")
./swb sync qwen --install       # git push HEAD -> instance + uv sync --frozen

cp ../mini-swe-runs/.env.example ../mini-swe-runs/.env   # QWEN_API_KEY, QWEN_BASE_URL, …
./swb env qwen

./swb run qwen yaml/qwen/smoke.yaml smoke-qwen
./swb run qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1 --detach   # long jobs in tmux
./swb summary qwen qwen-opt-v1
```

Attach to a running tmux job:

```bash
./swb ssh qwen
tmux attach -t swebench-qwen-opt-v1
tail -f /opt/swe-bench/mini-swe-runs/results/<RUN_NAME>/minisweagent.log
```

## The golden data snapshot (no more 300GB prepull per stage)

The ~500 SWE-bench Verified instance images total ~300GB. Instead of pulling them on every fresh volume, pull them **once** on a reference stage, snapshot that volume, and provision every new stage's data volume from the snapshot:

```bash
# One time (or whenever the image set changes):
./swb deploy golden && ./swb bootstrap golden && ./swb sync golden --install && ./swb env golden
./swb prepull golden              # the slow ~300GB pull — done once ever
./swb snapshot-data golden        # freeze /data, snapshot, save id to cloud/.snapshot-id

# Every new stage starts with all images already on disk:
./swb deploy kimi                 # picks up cloud/.snapshot-id automatically
./swb bootstrap kimi              # detects existing ext4 — no mkfs, no prepull
```

Notes:

- `DATA_SNAPSHOT_ID=snap-xxxx ./swb deploy <stage>` overrides the file; `DATA_SNAPSHOT_ID=none` forces a blank volume.
- The snapshot only matters at volume **creation**. Existing stages are never touched (`runner.ts` ignores `snapshotId`/`size` changes to prevent accidental volume replacement).
- `DATA_VOLUME_GB` is raised automatically if it's smaller than the snapshot.
- Blocks lazy-hydrate from S3 on first read — the first run after a snapshot restore reads images slightly slower; subsequent reads are full speed.
- Images missing from the snapshot (e.g. a new SWE-bench release) pull lazily during evaluation (`--namespace swebench` in the harness) — `prepull` is an **optional** warm-up, not a required step.
- Refresh: on `golden`, `./swb prepull golden` (pulls only deltas) → `./swb snapshot-data golden`.

## Code sync (git push, not rsync)

`./swb sync <stage> [commit-ish]` deploys **committed code only**:

1. Resolves the commit (default: your current `HEAD`; any branch/tag/SHA works).
2. `git push --force` to a bare repo on the instance (`/data/repo.git`) over the same SSH-over-SSM transport — no GitHub round-trip, no token on the instance, delta transfer after the first push.
3. Checks that exact commit out into `/opt/swe-bench` and records it in `/opt/swe-bench/.deployed-sha`.

A dirty working tree prints a warning — uncommitted changes never deploy. Untracked files on the instance (`results/`, eval `logs/`, `.venv`, `.env`) are never touched. Gitignored files never transfer, so there is no exclude list to maintain.

```bash
./swb sync qwen                    # deploy local HEAD
./swb sync qwen my-branch          # deploy a branch
./swb sync qwen abc1234 --install  # deploy a SHA + uv sync --frozen
```

What's running on a stage is always answerable: `./swb ready qwen` prints the deployed SHA.

## Instance defaults

| Setting | Default |
|---------|---------|
| Type | `m6i.2xlarge` (8 vCPU, 32 GiB) |
| Data volume | 500 GiB gp3 on `/data` (from golden snapshot when available) |
| AMI | Ubuntu 24.04 amd64 (Python 3.12) |
| Repo on instance | `/opt/swe-bench` (root volume); deploy repo at `/data/repo.git` |
| Region | `us-east-1` |

Override at deploy time:

```bash
INSTANCE_TYPE=m6i.4xlarge DATA_VOLUME_GB=600 ./swb deploy qwen
```

Grow an existing stage volume in place (data preserved):

```bash
./swb resize qwen 600
```

## Commands

Run `./swb help` for the full reference.

| Command | Purpose |
|---------|---------|
| `deploy <stage>` | `sst deploy` + wait for SSM (golden snapshot for new stages) |
| `bootstrap <stage>` | Instance setup via SSM (Docker on `/data`, uv, AWS CLI, deploy repo) — idempotent, re-run when idle |
| `sync <stage> [commit] [--install]` | git push + checkout (+ `uv sync --frozen`) |
| `env <stage> [--dry-run\|--diff]` | Copy `mini-swe-runs/.env` to the instance |
| `run <stage> <yaml> <RUN_NAME> [--detach]` | Run a benchmark (foreground, or detached tmux) |
| `status` / `evaluate` / `summary` / `salvage` / `prepull` / `storage` | Thin wrappers over `mini-swe-runs/scripts/*` on the instance |
| `results push <stage> <RUN_NAME> [--force] [--local]` | Zip `results/<RUN_NAME>/` → R2 |
| `results restore <stage> <RUN_NAME> [--force] [--local]` | R2 → unzip into `results/` (resume) |
| `results pull <stage> <RUN_NAME> [--logs] [--trajectories]` | Copy artifacts to the laptop |
| `snapshot-data <stage>` | Create/refresh the golden data snapshot |
| `ssh` / `connect` | Interactive shell (SSH-over-SSM / plain SSM) |
| `ready <stage>` | Readiness checks + deployed SHA + image count |
| `resize <stage> <GB>` | Grow data volume + ext4 |
| `stop` / `start` / `destroy` | Lifecycle (destroy = triple confirm, deletes data volume) |

Old script → new command:

| Old | New |
|-----|-----|
| `infra/deploy.sh`, `infra/bootstrap.sh`, `infra/destroy.sh`, `infra/stop.sh`, `infra/start.sh` | `swb deploy/bootstrap/destroy/stop/start` |
| `infra/sync.sh [--install]` (rsync) | `swb sync [--install]` (git push) |
| `infra/push-env.sh` | `swb env` |
| `infra/install-deps.sh` | `swb sync --install` |
| `infra/ssh.sh`, `infra/connect.sh` | `swb ssh`, `swb connect` |
| `infra/resize-data-volume.sh` | `swb resize` |
| `scripts/run.sh`, `scripts/run-tmux.sh` | `swb run [--detach]` |
| `scripts/status.sh`, `evaluate.sh`, `summary.sh`, `salvage_preds.sh`, `prepull.sh`, `docker_storage.sh` | `swb status/evaluate/summary/salvage/prepull/storage` |
| `scripts/upload-results.sh`, `restore-results.sh`, `pull-results.sh` | `swb results push/restore/pull` |

## Bootstrap

`./swb bootstrap <stage>` pushes [`remote/bootstrap.sh`](remote/bootstrap.sh) to the instance via SSM (the only pre-git-sync step) and runs it as root. Idempotent — but it restarts docker if storage config changed, so re-run only while idle.

**Docker storage:** Docker CE uses the containerd snapshotter — image layers live under containerd `root`, not Docker `data-root`:

| Path | Purpose |
|------|---------|
| `/data/containerd` | Image layers and snapshots (~300G for 500 Verified images) |
| `/data/docker` | Docker metadata (`daemon.json` `data-root`) |
| `/data/repo.git` | Bare git repo (push target for `swb sync`) |
| `/opt/swe-bench` | Checked-out worktree + results (root volume) |

Configs are written as complete static files (no in-place editing). Device discovery excludes the root disk rather than guessing device names. A sentinel at `/var/lib/swe-bench/bootstrap.done` records the bootstrap version.

Bootstrap also migrates instances from the old rsync layout (`/opt/swe-bench` symlink → `/data/swe-bench`): the symlink becomes a real directory and legacy `results/` + `.env` move over automatically. After verifying, `rm -rf /data/swe-bench` on the instance reclaims the space.

Logs on the instance: `/var/log/swe-bench-bootstrap.log`

## Python toolchain (`mini-swe-runs`)

Pinned in [`../mini-swe-runs/pyproject.toml`](../mini-swe-runs/pyproject.toml) + `uv.lock`: `mini-swe-agent==2.3.0`, `datacurve-pier`, `swebench`, `datasets`. Run scripts use `uv run`; Python **3.12** is uv-managed. `swb sync --install` runs `uv sync --frozen` on the instance.

## Secrets (`.env`)

Required for runs: `QWEN_API_KEY`, `QWEN_BASE_URL` (and `KIMI_*` for kimi yamls). `.env` is gitignored and never travels with `swb sync` — push it with `swb env <stage>`.

Optional for R2 archival (bucket created out of band in Cloudflare):

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
./swb results push qwen verified-full-v2
./swb results push qwen verified-full-v2 --force    # overwrite existing archive
./swb results push qwen smoke --local               # zip + upload from the laptop checkout

# Resume on a fresh instance (after sync + env):
./swb results restore qwen verified-full-v2
./swb run qwen yaml/qwen/verified-full.yaml verified-full-v2 --detach
```

R2 object key (stable, per run name): `{R2_PREFIX}/{RUN_NAME}/swe-bench-{RUN_NAME}.zip`. R2 credentials are scoped per-invocation (`lib/r2.sh`) — they are never exported into the shell, so they can't poison real-AWS calls.

## Slack notifications (optional, Jenkins-style)

The long-running jobs — `prepull`, `snapshot-data`, `run`, `evaluate` — post to Slack: a start (▶️), periodic progress (⏳, default every 30 min), and a terminal success (✅) / failure (❌). Each message is tagged with the **stage** (cloud env), **job**, and **run name**; failures `@here` the channel. Absent config = silently disabled.

Setup:

1. Create a Slack app → enable **Incoming Webhooks** → **Add New Webhook to Workspace** → pick a channel → copy the URL.
2. Add it to `mini-swe-runs/.env` (gitignored): `SLACK_WEBHOOK_URL=https://hooks.slack.com/services/…` (optional `SLACK_NOTIFY_INTERVAL_SECS=1800`).
3. `swb env <stage>` to push `.env` to the instance.

How it works: jobs **self-report** from where they run. Instance jobs (`run`/`evaluate`/`prepull`) are wrapped by `cloud/remote/run_job.sh`, which reads `SLACK_WEBHOOK_URL` from the synced `.env` and posts via `cloud/remote/notify.sh` — so notifications keep flowing even when your laptop is closed and the job is detached in tmux. `snapshot-data` posts from the laptop. The webhook URL is a credential; it lives only in `.env` and is rotatable by recreating the webhook in the Slack app.

## Persistence

| Action | Data on `/data`? |
|--------|------------------|
| EC2 **stop** / **start** (`swb stop/start`) | Yes (same instance, volume attached) |
| `swb results pull/push/restore` | Export / archive / restore copy |
| `swb destroy <stage>` | **No** — SST removes stack and data volume |

Results live on the **root volume** (`/opt/swe-bench/mini-swe-runs/results/`) — they survive stop/start, and `swb results push` archives them to R2 before a destroy.

## Cost (us-east-1, on-demand)

- `m6i.2xlarge` ≈ **$0.38/hr** while running
- 500 GiB gp3 ≈ **~$40/mo** while volume exists (including while stopped)
- Golden snapshot ≈ **$0.05/GB-mo** of actual data (one-time, shared by all stages)
- `swb destroy` stops volume billing

## Debugging

```bash
./swb ready qwen                  # readiness + deployed SHA + image count
./swb storage qwen                # containerd root, / vs /data headroom
./swb status qwen smoke-qwen
./swb summary qwen smoke-qwen

./swb ssh qwen                    # land in mini-swe-runs/
tail -f results/<RUN_NAME>/minisweagent.log
```

Bootstrap log on the instance: `/var/log/swe-bench-bootstrap.log`

## Recovering from a disk-full run

If a full run ends with mass `docker run` exit **125** and hundreds of **empty patches** in `preds.json` (infrastructure failures, not model quality):

1. Re-bootstrap to fix storage: `./swb bootstrap <stage>`
2. On the instance, remove empty-patch entries from `preds.json` (keep successes; do **not** use `--redo-existing` unless you want to redo all 500)
3. Warm the cache if needed: `./swb prepull <stage>`
4. Re-run agent: `./swb run <stage> <yaml> <RUN_NAME> --detach`
5. Re-evaluate: `./swb evaluate <stage> <RUN_NAME>`

## SST only

```bash
cd cloud
export AWS_REGION=us-east-1
npx sst deploy --stage qwen      # set DATA_SNAPSHOT_ID / DATA_VOLUME_GB as needed
npx sst remove --stage qwen
```

Non-`prod` stages use `removal: remove` in `sst.config.ts`; a `prod` stage retains the whole stack on remove. Outputs include `instanceId`, `instancePublicIp`, `dataVolumeId`, `dataSnapshotId`, `repoPath`, `miniSweRunsPath`.
