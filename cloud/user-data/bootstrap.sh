#!/bin/bash
# Idempotent runner setup: Docker, uv, /data volume, repo paths.
# Run via: ./infra/bootstrap.sh <stage>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/swe-bench-bootstrap.log
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[bootstrap $(date -Iseconds)] $*" | tee -a "$LOG" >&2; }

CONTAINERD_ROOT="/data/containerd"
DOCKER_DATA_ROOT="/data/docker"
OLD_CONTAINERD_ROOT="/var/lib/containerd"

log "start (pid $$)"

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

containerd_config_root() {
  if [[ ! -f /etc/containerd/config.toml ]]; then
    echo ""
    return
  fi
  python3 - <<'PY'
import re
text = open("/etc/containerd/config.toml").read()
m = re.search(r'^\s*root\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "")
PY
}

dir_has_content() {
  local d="$1"
  [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null || true)" ]]
}

configure_containerd_on_data() {
  local current_root migrated=0

  if [[ ! -f /etc/containerd/config.toml ]]; then
    log "generate /etc/containerd/config.toml"
    containerd config default >/etc/containerd/config.toml
  fi

  current_root="$(containerd_config_root)"
  if [[ "$current_root" == "$CONTAINERD_ROOT" ]]; then
    log "containerd root already $CONTAINERD_ROOT"
    return 0
  fi

  log "configure containerd root -> $CONTAINERD_ROOT (was: ${current_root:-<unset>})"
  stop_docker_stack
  mkdir -p "$CONTAINERD_ROOT"

  if dir_has_content "$OLD_CONTAINERD_ROOT" && ! dir_has_content "$CONTAINERD_ROOT"; then
    if [[ -L "$OLD_CONTAINERD_ROOT" ]]; then
      log "warn: $OLD_CONTAINERD_ROOT is a symlink; skipping rsync"
    else
      log "migrate containerd data: $OLD_CONTAINERD_ROOT -> $CONTAINERD_ROOT"
      rsync -aHX "$OLD_CONTAINERD_ROOT/" "$CONTAINERD_ROOT/"
      migrated=1
    fi
  fi

  python3 - "$CONTAINERD_ROOT" <<'PY'
import re, sys
path = "/etc/containerd/config.toml"
root = sys.argv[1]
text = open(path).read()
if re.search(r'^\s*root\s*=', text, re.M):
    text = re.sub(r'^\s*root\s*=\s*"[^"]*"', f'root = "{root}"', text, count=1, flags=re.M)
else:
    text = f'root = "{root}"\n' + text
open(path, "w").write(text)
PY

  start_docker_stack

  docker info >/dev/null
  local images_before
  images_before="$(docker images -q 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "$migrated" -eq 1 ]]; then
    if [[ "$images_before" -gt 0 ]]; then
      log "migration ok: $images_before docker images visible"
      if [[ -d "$OLD_CONTAINERD_ROOT" && ! -L "$OLD_CONTAINERD_ROOT" ]]; then
        log "reclaim root disk: rm -rf $OLD_CONTAINERD_ROOT"
        rm -rf "$OLD_CONTAINERD_ROOT"
      fi
    else
      log "warn: migration finished but docker images list is empty — keeping $OLD_CONTAINERD_ROOT"
    fi
  fi

  du -sh "$CONTAINERD_ROOT" "$DOCKER_DATA_ROOT" 2>/dev/null || true
  df -h / /data
}

configure_docker_daemon() {
  mkdir -p /etc/docker
  if python3 - "$DOCKER_DATA_ROOT" <<'PY'
import json, sys
path = "/etc/docker/daemon.json"
root = sys.argv[1]
try:
    data = json.load(open(path))
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    data = {}
if data.get("data-root") == root:
    raise SystemExit(0)
data["data-root"] = root
open(path, "w").write(json.dumps(data, indent=2) + "\n")
print("updated", path)
PY
  then
    log "docker daemon.json data-root=$DOCKER_DATA_ROOT"
  fi
}

link_docker_data_root() {
  if [[ -L /var/lib/docker ]]; then
    return 0
  fi
  stop_docker_stack
  if [[ -d /var/lib/docker && ! -L /var/lib/docker ]]; then
    rm -rf /var/lib/docker
  fi
  ln -sfn "$DOCKER_DATA_ROOT" /var/lib/docker
}

verify_storage_layout() {
  local root_avail data_avail ctr_root
  ctr_root="$(containerd_config_root)"
  root_avail="$(df --output=avail / | tail -1 | tr -d ' ')"
  data_avail="$(df --output=avail /data 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"

  log "storage verify: containerd_root=$ctr_root root_free_kb=$root_avail data_free_kb=$data_avail"
  if [[ "$ctr_root" != "$CONTAINERD_ROOT" ]]; then
    log "error: containerd root must be $CONTAINERD_ROOT (got ${ctr_root:-<unset>})"
    return 1
  fi
  if [[ "$root_avail" -lt $((10 * 1024 * 1024)) ]]; then
    log "warn: root / low on space ($((root_avail / 1024 / 1024))G free)"
  fi
  if [[ "$data_avail" -lt $((100 * 1024 * 1024)) ]]; then
    log "warn: /data low on space ($((data_avail / 1024 / 1024))G free)"
  fi
  du -sh "$CONTAINERD_ROOT" "$DOCKER_DATA_ROOT" 2>/dev/null || true
}

log "apt update"
wait_for_apt
apt-get update -qq

log "base packages"
wait_for_apt
apt-get install -y -qq \
  git curl jq tmux unzip zip ca-certificates gnupg \
  python3.12 python3.12-venv python3.12-dev python3-pip \
  build-essential \
  openssh-server ec2-instance-connect

log "docker apt repo"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION_ID}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
fi

if ! command -v docker >/dev/null 2>&1; then
  log "install docker packages"
  wait_for_apt
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi

systemctl enable containerd docker
usermod -aG docker ubuntu || true

log "uv"
if ! command -v uv >/dev/null 2>&1 && [[ ! -x /usr/local/bin/uv ]]; then
  curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi

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

wait_for_data_volume() {
  local i d
  for i in $(seq 1 60); do
    for d in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
      if [[ -b "$d" ]]; then
        log "data volume found: $d (attempt $i)"
        echo "$d"
        return 0
      fi
    done
    sleep 5
  done
  log "warn: no data volume after 5m — using root for docker/repo paths"
  return 1
}

DATA_DEV=""
if DATA_DEV="$(wait_for_data_volume)"; then
  if ! blkid "$DATA_DEV" | grep -q ext4; then
    log "format $DATA_DEV"
    mkfs.ext4 -F "$DATA_DEV"
  fi
  mkdir -p /data
  if ! grep -q ' /data ' /etc/fstab; then
    UUID=$(blkid -s UUID -o value "$DATA_DEV")
    echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  mount -a || mount "$DATA_DEV" /data
  mkdir -p "$DOCKER_DATA_ROOT" "$CONTAINERD_ROOT" /data/swe-bench /data/tmp
  chown -R ubuntu:ubuntu /data

  configure_docker_daemon
  link_docker_data_root
  configure_containerd_on_data

  if [[ ! -e /opt/swe-bench ]]; then
    ln -sfn /data/swe-bench /opt/swe-bench
  elif [[ -d /opt/swe-bench && ! -L /opt/swe-bench ]]; then
    log "replace root-owned /opt/swe-bench with symlink to /data/swe-bench"
    rm -rf /opt/swe-bench
    ln -sfn /data/swe-bench /opt/swe-bench
  fi
  chown -h ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true

  verify_storage_layout
else
  log "WARN: no /data volume — full SWE-bench Verified runs need the data EBS volume"
  mkdir -p /opt/swe-bench
  chown -R ubuntu:ubuntu /opt/swe-bench
  start_docker_stack
fi

mkdir -p /opt/swe-bench/mini-swe-runs
chown -R ubuntu:ubuntu /opt/swe-bench 2>/dev/null || chown -h ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true

log "verify docker"
docker info >/dev/null
getent group docker | grep -qw ubuntu
sudo -u ubuntu sg docker -c "docker info >/dev/null"

if [[ -x /opt/swe-bench/mini-swe-runs/scripts/docker_storage.sh ]]; then
  /opt/swe-bench/mini-swe-runs/scripts/docker_storage.sh --quiet || verify_storage_layout
else
  verify_storage_layout
fi

log "complete"
