#!/bin/bash
# Idempotent runner setup: Docker, uv, /data volume, repo paths.
# Run via: ./scripts/bootstrap.sh <stage>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/swe-bench-bootstrap.log
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[bootstrap $(date -Iseconds)] $*" | tee -a "$LOG" >&2; }

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

systemctl enable docker
systemctl start docker
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
  mkdir -p /data/docker /data/swe-bench /data/tmp
  chown -R ubuntu:ubuntu /data

  if [[ ! -L /var/lib/docker ]]; then
    systemctl stop docker || true
    if [[ -d /var/lib/docker && ! -L /var/lib/docker ]]; then
      rm -rf /var/lib/docker
    fi
    ln -sfn /data/docker /var/lib/docker
    systemctl start docker
  fi

  if [[ ! -e /opt/swe-bench ]]; then
    ln -sfn /data/swe-bench /opt/swe-bench
  elif [[ -d /opt/swe-bench && ! -L /opt/swe-bench ]]; then
    log "replace root-owned /opt/swe-bench with symlink to /data/swe-bench"
    rm -rf /opt/swe-bench
    ln -sfn /data/swe-bench /opt/swe-bench
  fi
  chown -h ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true
else
  mkdir -p /opt/swe-bench
  chown -R ubuntu:ubuntu /opt/swe-bench
fi

mkdir -p /opt/swe-bench/mini-swe-runs
chown -R ubuntu:ubuntu /opt/swe-bench 2>/dev/null || chown -h ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true

log "verify docker"
docker info >/dev/null
getent group docker | grep -qw ubuntu
sudo -u ubuntu sg docker -c "docker info >/dev/null"

log "complete"
