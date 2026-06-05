#!/usr/bin/env bash
# Report Docker/containerd storage layout and headroom.
# Exit 1 on misconfiguration (--quiet) or when --require-headroom fails.
#
# Usage:
#   ./scripts/docker_storage.sh              # full report
#   ./scripts/docker_storage.sh --quiet      # exit 1 only on misconfig
#   ./scripts/docker_storage.sh --require-headroom 150G
set -euo pipefail

QUIET=0
REQUIRE_HEADROOM_KB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --require-headroom)
      if command -v numfmt >/dev/null 2>&1; then
        REQUIRE_HEADROOM_KB=$(( $(numfmt --from=iec "$2") / 1024 ))
      else
        REQUIRE_HEADROOM_KB=$(( $(python3 -c "import sys; s=sys.argv[1].upper(); u={'K':1,'M':1024,'G':1024**2,'T':1024**3}; n=int(''.join(c for c in s if c.isdigit()) or 0); suf=next((c for c in reversed(s) if c in u), 'G'); print(n*u[suf])" "$2") ))
      fi
      shift 2
      ;;
    *) echo "usage: $0 [--quiet] [--require-headroom SIZE]" >&2; exit 2 ;;
  esac
done

EXPECTED_CONTAINERD_ROOT="/data/containerd"
MIN_ROOT_FREE_KB=$((10 * 1024 * 1024))  # 10 GiB

issues=()

containerd_root() {
  if [[ -f /etc/containerd/config.toml ]]; then
    python3 - <<'PY'
import re
text = open("/etc/containerd/config.toml").read()
m = re.search(r'^\s*root\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "")
PY
  fi
}

report() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$@"
  fi
}

ROOT_CONTAINERD="$(containerd_root)"
MOUNT_DATA="$(df --output=avail /data 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
MOUNT_ROOT="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"

if [[ ! -d /data ]]; then
  issues+=("missing /data mount")
elif [[ "$ROOT_CONTAINERD" != "$EXPECTED_CONTAINERD_ROOT" ]]; then
  issues+=("containerd root is '${ROOT_CONTAINERD:-<unset>}' (expected $EXPECTED_CONTAINERD_ROOT)")
fi

if [[ "$MOUNT_ROOT" -lt "$MIN_ROOT_FREE_KB" ]]; then
  issues+=("root / has only $((MOUNT_ROOT / 1024 / 1024))G free (want >=10G)")
fi

if [[ -n "$REQUIRE_HEADROOM_KB" && "$MOUNT_DATA" -lt "$REQUIRE_HEADROOM_KB" ]]; then
  issues+=("/data has only $((MOUNT_DATA / 1024 / 1024))G free (need $(numfmt --to=iec "$REQUIRE_HEADROOM_KB" 2>/dev/null || echo "${REQUIRE_HEADROOM_KB}K"))")
fi

if [[ "$QUIET" -eq 1 ]]; then
  if ((${#issues[@]})); then
    printf '%s\n' "${issues[@]}" >&2
    exit 1
  fi
  exit 0
fi

echo "=== Docker / containerd storage ==="
echo
echo "--- mounts ---"
df -h / /data 2>/dev/null || df -h /
echo
echo "--- containerd ---"
echo "config root: ${ROOT_CONTAINERD:-<unset>} (expected: $EXPECTED_CONTAINERD_ROOT)"
for p in /data/containerd /data/docker /var/lib/containerd; do
  if [[ -e "$p" ]]; then
    du -sh "$p" 2>/dev/null || true
  fi
done
echo
if command -v docker >/dev/null 2>&1; then
  echo "--- docker info ---"
  docker info 2>/dev/null | grep -E '^( Storage Driver| Docker Root Dir| Driver-type):' || true
  echo
  echo "--- docker system df ---"
  docker system df 2>/dev/null | head -5 || true
  echo
  echo "image count: $(docker images -q 2>/dev/null | wc -l | tr -d ' ')"
else
  echo "(docker not installed or not running)"
fi

if ((${#issues[@]})); then
  echo
  echo "WARNINGS:"
  printf '  - %s\n' "${issues[@]}"
  exit 1
fi
