#!/bin/bash
# EC2 first-boot: Docker, uv, SSM+SSH, persistent /data for repo + Docker.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[bootstrap] $*"; }

log "apt update"
apt-get update -qq

log "base packages"
apt-get install -y -qq \
  git curl jq tmux unzip zip ca-certificates gnupg \
  python3.12 python3.12-venv python3-pip \
  openssh-server awscli

# Docker CE
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION_ID}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi

systemctl enable --now docker
usermod -aG docker ubuntu || true

# uv
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi

# SSM agent (Ubuntu images often include it; ensure running)
if systemctl list-unit-files amazon-ssm-agent.service &>/dev/null; then
  systemctl enable --now amazon-ssm-agent || true
fi

# SSH over SSM (Session Manager)
mkdir -p /etc/systemd/system/sshd.service.d
cat >/etc/systemd/system/sshd.service.d/ssm.conf <<'EOF'
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
systemctl daemon-reload
systemctl enable --now ssh || systemctl enable --now sshd || true

# Persistent data volume (/dev/sdf or nvme1n1 on Nitro)
DATA_DEV=""
for d in /dev/sdf /dev/nvme1n1 /dev/xvdf; do
  if [[ -b "$d" ]]; then DATA_DEV="$d"; break; fi
done

if [[ -n "$DATA_DEV" ]]; then
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
  fi
  chown -h ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true
fi

mkdir -p /opt/swe-bench
chown ubuntu:ubuntu /opt/swe-bench 2>/dev/null || true

log "bootstrap complete"
