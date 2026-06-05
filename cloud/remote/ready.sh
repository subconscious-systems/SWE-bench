#!/usr/bin/env bash
# Instance readiness checks. Self-contained: runs via SSM right after
# bootstrap (before any git sync) and by path afterwards.
set -euo pipefail

fail() { echo "not ready: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker missing"
docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1 || fail "docker daemon not running"
getent group docker | grep -qw ubuntu || fail "ubuntu not in docker group"
sudo -u ubuntu sg docker -c "docker info >/dev/null" || fail "ubuntu cannot use docker"
test -x /usr/local/bin/uv || command -v uv >/dev/null 2>&1 || fail "uv missing"
mountpoint -q /data || fail "/data not mounted"
grep -q 'root = "/data/containerd"' /etc/containerd/config.toml || fail "containerd root not on /data"
test -d /data/repo.git || fail "deploy repo missing (re-run: swb bootstrap)"
test -f /var/lib/swe-bench/bootstrap.done || fail "bootstrap sentinel missing (re-run: swb bootstrap)"

avail="$(df --output=avail /data | tail -1 | tr -d ' ')"
if [[ "$avail" -le $((100 * 1024 * 1024)) ]]; then
  echo "warn: /data has <100G free ($((avail / 1024 / 1024))G)" >&2
fi

if [[ -x /opt/swe-bench/mini-swe-runs/scripts/docker_storage.sh ]]; then
  /opt/swe-bench/mini-swe-runs/scripts/docker_storage.sh --quiet || true
fi

echo "ready: docker=$(docker --version 2>/dev/null || sudo docker --version) uv=$(/usr/local/bin/uv --version 2>/dev/null || uv --version)"
echo "deployed: $(cat /opt/swe-bench/.deployed-sha 2>/dev/null || echo '<not synced yet>')"
echo "images: $(docker images -q 2>/dev/null | wc -l | tr -d ' ')"
