#!/bin/bash
# Idempotent runner setup: Docker on /data, uv, AWS CLI, data volume mount,
# git deploy repo. Runs as root.
#
# Self-contained by design: it is pushed to the instance via SSM
# (cloud/lib/ssm.sh) BEFORE the repo exists there, so it cannot source
# anything from the repo — static configs live inline as heredocs.
#
# Safe to re-run when the instance is idle. Avoid re-running during active
# benchmark runs: a docker/containerd config change restarts the stack.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/swe-bench-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
log() { echo "[bootstrap $(date -Iseconds)] $*" >&2; }

BOOTSTRAP_VERSION=2
CONTAINERD_ROOT="/data/containerd"
DOCKER_DATA_ROOT="/data/docker"
WORKTREE="/opt/swe-bench"
DEPLOY_GIT_DIR="/data/repo.git"
SENTINEL="/var/lib/swe-bench/bootstrap.done"

log "start (pid $$, version $BOOTSTRAP_VERSION)"

wait_for_apt() {
  local i
  for i in $(seq 1 90); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      return 0
    fi
    log "waiting for apt/dpkg lock (attempt $i/90) ..."
    sleep 5
  done
  log "error: apt lock still held after 7.5m"
  return 1
}

stop_docker_stack() {
  systemctl stop docker docker.socket containerd 2>/dev/null || true
}

start_docker_stack() {
  systemctl enable containerd docker
  systemctl start containerd
  systemctl start docker
}

# write_if_changed <dest>: reads desired content from stdin; installs it only
# if different. Returns 0 when the file changed, 1 when already up to date.
write_if_changed() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

# --- packages (docker repo first, so ONE apt-get update covers everything) ---
log "docker apt repo"
command -v curl >/dev/null 2>&1 || { wait_for_apt; apt-get update -qq; apt-get install -y -qq curl ca-certificates; }
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  # shellcheck disable=SC1091
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION_ID}") stable" \
    > /etc/apt/sources.list.d/docker.list
fi

log "apt update + install"
wait_for_apt
apt-get update -qq
wait_for_apt
apt-get install -y -qq \
  git curl jq tmux unzip zip ca-certificates gnupg \
  python3.12 python3.12-venv python3.12-dev python3-pip \
  build-essential \
  openssh-server ec2-instance-connect \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin

usermod -aG docker ubuntu || true

log "uv"
if ! command -v uv >/dev/null 2>&1 && [[ ! -x /usr/local/bin/uv ]]; then
  curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi

log "aws cli v2"
if ! command -v aws >/dev/null 2>&1; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64) aws_arch=x86_64 ;;
    aarch64|arm64) aws_arch=aarch64 ;;
    *) log "error: unsupported arch for aws cli: $arch"; exit 1 ;;
  esac
  aws_tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "$aws_tmp/awscliv2.zip"
  unzip -q "$aws_tmp/awscliv2.zip" -d "$aws_tmp"
  "$aws_tmp/aws/install" -i /usr/local/aws-cli -b /usr/local/bin --update
  rm -rf "$aws_tmp"
fi
log "aws $(aws --version 2>&1 | head -1)"

# --- remote access lifelines ---
if systemctl list-unit-files amazon-ssm-agent.service &>/dev/null; then
  systemctl enable --now amazon-ssm-agent || true
fi
mkdir -p /etc/systemd/system/sshd.service.d
cat >/etc/systemd/system/sshd.service.d/ssm.conf <<'EOF'
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
systemctl daemon-reload
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true

# --- systemd hardening ---
configure_systemd_hardening() {
  # Docker/containerd must never start without /data: image stores live there,
  # and a missed mount would silently fill the root disk instead.
  local unit
  for unit in docker containerd; do
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    cat >"/etc/systemd/system/${unit}.service.d/data-mount.conf" <<'EOF'
[Unit]
RequiresMountsFor=/data
EOF
  done

  # Keep the remote-access lifelines alive under memory pressure so the box
  # stays reachable even if an eval run goes pathological.
  for unit in amazon-ssm-agent.service snap.amazon-ssm-agent.amazon-ssm-agent.service ssh.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
      mkdir -p "/etc/systemd/system/${unit}.d"
      cat >"/etc/systemd/system/${unit}.d/survival.conf" <<'EOF'
[Service]
OOMScoreAdjust=-1000
EOF
    fi
  done

  # Cap journald so logs cannot eat the root disk.
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/cap.conf <<'EOF'
[Journal]
SystemMaxUse=1G
EOF

  systemctl daemon-reload
  systemctl restart systemd-journald 2>/dev/null || true
  log "systemd hardening: RequiresMountsFor=/data, ssm/ssh OOM protection, journald cap"
}
configure_systemd_hardening

# --- data volume: discover by "the EBS disk that is not the root disk" ---
# (device names vary by virtualization: /dev/sdf attaches as /dev/nvme1n1 on
# nitro. Excluding the root disk is robust to naming; m6i has no instance-store
# NVMe that could confuse this.)
wait_for_data_device() {
  local root_src root_disk i name type
  root_src="$(findmnt -n -o SOURCE /)"
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
  for i in $(seq 1 60); do
    while read -r name type; do
      [[ "$type" == "disk" ]] || continue
      [[ "$name" == "$root_disk" ]] && continue
      log "data volume found: /dev/$name (attempt $i)"
      echo "/dev/$name"
      return 0
    done < <(lsblk -dn -o NAME,TYPE)
    sleep 5
  done
  log "error: no data volume after 5m"
  return 1
}

DATA_DEV="$(wait_for_data_device)" || {
  log "error: data volume required — aborting bootstrap"
  exit 1
}

# Only format a blank volume; the blkid guard preserves an existing filesystem
# (and its cached docker images) on re-bootstrap or stop/start reattach.
if ! blkid "$DATA_DEV" | grep -q ext4; then
  log "format $DATA_DEV"
  mkfs.ext4 -F "$DATA_DEV"
fi
mkdir -p /data
if ! grep -q ' /data ' /etc/fstab; then
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q /data || mount -a || mount "$DATA_DEV" /data
mountpoint -q /data || { log "error: /data not mounted"; exit 1; }

mkdir -p "$DOCKER_DATA_ROOT" "$CONTAINERD_ROOT" /data/tmp
# Only /data/tmp belongs to ubuntu — never chown -R /data (the docker dirs are
# root-owned and can hold 300GB of image layers).
chown ubuntu:ubuntu /data/tmp

# --- docker/containerd storage on /data (static configs; no regex editing) ---
configure_docker_storage() {
  local changed=0
  mkdir -p /etc/docker /etc/containerd

  # SWE-bench test runs can emit GBs of stdout; cap per-container logs.
  # Eval-image builds accumulate cache; let the builder GC it.
  if write_if_changed /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "2"
  },
  "builder": {
    "gc": {
      "enabled": true,
      "defaultKeepStorage": "40GB"
    }
  }
}
EOF
  then changed=1; fi

  # Minimal config: containerd applies defaults for everything unspecified.
  if write_if_changed /etc/containerd/config.toml <<EOF
# Managed by swe-bench cloud bootstrap (cloud/remote/bootstrap.sh).
version = 2
root = "$CONTAINERD_ROOT"
EOF
  then changed=1; fi

  if [[ "$changed" == 1 ]]; then
    log "docker/containerd config changed; restarting stack"
    stop_docker_stack
    # Root is on /data now; drop any legacy store so it cannot eat the root disk.
    if [[ -d /var/lib/containerd && ! -L /var/lib/containerd ]]; then
      log "remove legacy containerd data at /var/lib/containerd"
      rm -rf /var/lib/containerd
    fi
  fi
  start_docker_stack
}
configure_docker_storage

# --- repo worktree (root volume) + bare deploy repo (git push target) ---
setup_deploy_repo() {
  # Migrate the old rsync layout: /opt/swe-bench was a symlink to /data/swe-bench.
  local legacy="/data/swe-bench/mini-swe-runs"
  if [[ -L "$WORKTREE" ]]; then
    log "migrate: replacing symlink $WORKTREE with a real directory"
    rm -f "$WORKTREE"
  fi
  mkdir -p "$WORKTREE/mini-swe-runs"
  if [[ -d "$legacy/results" && ! -e "$WORKTREE/mini-swe-runs/results" ]]; then
    local need avail
    need="$(du -sk "$legacy/results" | cut -f1)"
    avail="$(df --output=avail -k / | tail -1 | tr -d ' ')"
    if (( need + 10 * 1024 * 1024 < avail )); then
      log "migrate: moving legacy results ($((need / 1024)) MiB) to $WORKTREE/mini-swe-runs/"
      mv "$legacy/results" "$WORKTREE/mini-swe-runs/results"
    else
      log "warn: legacy results too large for root volume; left at $legacy/results"
    fi
  fi
  if [[ -f "$legacy/.env" && ! -f "$WORKTREE/mini-swe-runs/.env" ]]; then
    log "migrate: copying legacy .env"
    cp -p "$legacy/.env" "$WORKTREE/mini-swe-runs/.env"
  fi
  chown -R ubuntu:ubuntu "$WORKTREE"

  if [[ ! -d "$DEPLOY_GIT_DIR" ]]; then
    log "init bare deploy repo $DEPLOY_GIT_DIR"
    git init --bare --initial-branch=deploy "$DEPLOY_GIT_DIR" >/dev/null
  fi
  chown -R ubuntu:ubuntu "$DEPLOY_GIT_DIR"
}
setup_deploy_repo

# --- verify ---
log "verify docker"
docker info >/dev/null
getent group docker | grep -qw ubuntu
sudo -u ubuntu sg docker -c "docker info >/dev/null"

ctr_root="$(grep -E '^root = ' /etc/containerd/config.toml | head -1 | cut -d'"' -f2)"
if [[ "$ctr_root" != "$CONTAINERD_ROOT" ]]; then
  log "error: containerd root must be $CONTAINERD_ROOT (got ${ctr_root:-<unset>})"
  exit 1
fi
df -h / /data
du -sh "$CONTAINERD_ROOT" "$DOCKER_DATA_ROOT" 2>/dev/null || true

mkdir -p "$(dirname "$SENTINEL")"
{
  echo "version=$BOOTSTRAP_VERSION"
  echo "date=$(date -Iseconds)"
} > "$SENTINEL"
log "complete"
