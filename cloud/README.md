# SWE-bench EC2 runner (SST)

Provision a dedicated **x86_64** EC2 host for [mini-swe-runs](../mini-swe-runs/) (SWE-bench Verified × mini-swe-agent), with **SSM/SSH** access, persistent disk, **authenticated Docker Hub** pulls for eval images, and optional **Cloudflare R2** archival.

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
./swb deploy qwen               # SST deploy + wait for SSM (blank data volume)
./swb bootstrap qwen            # Docker on /data, uv, deploy repo (idempotent)

git commit ...                  # sync deploys COMMITTED code (see "Code sync")
./swb sync qwen --install       # git push HEAD -> instance + uv sync --frozen

cp ../mini-swe-runs/.env.example ../mini-swe-runs/.env   # QWEN_API_KEY, DOCKERHUB_*, …
./swb env qwen                  # push .env + docker login (so eval images aren't rate-limited)

./swb run qwen yaml/qwen/smoke.yaml smoke-qwen   # eval images pull on demand, authenticated
./swb run qwen yaml/qwen/optimized-v1.yaml qwen-opt-v1 --detach   # long jobs in tmux
./swb summary qwen qwen-opt-v1
```

Attach to a running tmux job:

```bash
./swb ssh qwen
tmux attach -t swebench-qwen-opt-v1
tail -f /opt/swe-bench/mini-swe-runs/results/<RUN_NAME>/minisweagent.log
```

## Eval images (authenticated Docker pull)

The ~500 SWE-bench Verified instance images total ~300GB. They live on Docker Hub under `swebench/sweb.eval.x86_64.*` and pull **on demand** during a run: the agent does `docker run <image>` (auto-pulls if missing) and the eval harness does get-then-pull, so each image downloads once, the first time it's needed — over the instance's in-region ~1 Gbps link, then it's cached on `/data/containerd` for the life of the volume.

The only requirement is **Docker Hub authentication** so those pulls aren't throttled by anonymous rate limits (the 429s). Put a read-only token in `.env` and `swb env` logs the instance in:

```bash
# mini-swe-runs/.env
DOCKERHUB_USER=your-dockerhub-username
DOCKERHUB_TOKEN=dckr_pat_…        # Docker Hub → Account settings → Personal access tokens (read-only)
```

```bash
./swb env qwen          # pushes .env AND runs docker login on the instance
./swb docker-login qwen # re-auth only (e.g. after rotating the token)
```

Notes:

- **Lazy by default** — no upfront bulk download. Pulls spread across the run and overlap compute, staying under rate windows.
- **Optional warm-up:** `./swb prepull qwen` pre-pulls all (or N) images before a big run if you'd rather not pay per-image latency mid-run. It no-ops on images already present.
- **Rate limits:** authenticated **free** Docker Hub still has a 6h pull cap; lazy-pull-during-run rarely hits it. For heavy upfront prepulls, a **Pro** account is effectively unlimited.
- Images cache on `/data/containerd`; they survive stop/start and persist until the volume is destroyed.

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
| Data volume | 500 GiB gp3 on `/data` (blank; eval images pull on demand) |
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
| `deploy <stage>` | `sst deploy` + wait for SSM (blank data volume) |
| `bootstrap <stage>` | Instance setup via SSM (Docker on `/data`, uv, AWS CLI, deploy repo) — idempotent, re-run when idle |
| `sync <stage> [commit] [--install]` | git push + checkout (+ `uv sync --frozen`) |
| `env <stage> [--dry-run\|--diff]` | Push `mini-swe-runs/.env` + docker login on the instance |
| `docker-login <stage>` | (Re-)authenticate the instance to Docker Hub from `.env` |
| `run <stage> <yaml> <RUN_NAME> [--detach]` | Run a benchmark (foreground, or detached tmux) |
| `status` / `evaluate` / `summary` / `salvage` / `prepull` / `storage` | Thin wrappers over `mini-swe-runs/scripts/*` on the instance |
| `results push <stage> <RUN_NAME> [--force] [--local]` | Zip `results/<RUN_NAME>/` → R2 |
| `results restore <stage> <RUN_NAME> [--force] [--local]` | R2 → unzip into `results/` (resume) |
| `results pull <stage> <RUN_NAME> [--logs] [--trajectories]` | Copy artifacts to the laptop |
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

The long-running jobs — `prepull`, `run`, `evaluate` — post to Slack: a start (▶️), periodic progress (⏳, default every 30 min), and a terminal success (✅) / failure (❌). Each message is tagged with the **stage** (cloud env), **job**, and **run name**; failures `@here` the channel. Absent config = silently disabled.

Setup:

1. Create a Slack app → enable **Incoming Webhooks** → **Add New Webhook to Workspace** → pick a channel → copy the URL.
2. Add it to `mini-swe-runs/.env` (gitignored): `SLACK_WEBHOOK_URL=https://hooks.slack.com/services/…` (optional `SLACK_NOTIFY_INTERVAL_SECS=1800`).
3. `swb env <stage>` to push `.env` to the instance.

How it works: jobs **self-report** from the instance. `run`/`evaluate`/`prepull` are wrapped by `cloud/remote/run_job.sh`, which reads `SLACK_WEBHOOK_URL` from the synced `.env` and posts via `cloud/remote/notify.sh` — so notifications keep flowing even when your laptop is closed and the job is detached in tmux. The webhook URL is a credential; it lives only in `.env` and is rotatable by recreating the webhook in the Slack app.

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
npx sst deploy --stage qwen      # set DATA_VOLUME_GB / INSTANCE_TYPE as needed
npx sst remove --stage qwen
```

Non-`prod` stages use `removal: remove` in `sst.config.ts`; a `prod` stage retains the whole stack on remove. Outputs include `instanceId`, `instancePublicIp`, `dataVolumeId`, `repoPath`, `miniSweRunsPath`.
