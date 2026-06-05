#!/usr/bin/env bash
# Upload a file to Cloudflare R2.
#
# Usage: r2-upload.sh <LOCAL_PATH> <OBJECT_KEY> [--force]
#   Loads R2_* from .env in cwd (or mini-swe-runs/.env).
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=r2-common.sh
source "$LIB_DIR/r2-common.sh"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <LOCAL_PATH> <OBJECT_KEY> [--force]" >&2
  exit 2
fi

LOCAL_PATH="$1"
OBJECT_KEY="$2"
FORCE=0
shift 2
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

[[ -f "$LOCAL_PATH" ]] || { echo "error: file not found: $LOCAL_PATH" >&2; exit 1; }

r2_ensure_tools
r2_load_env
r2_confirm_overwrite "$OBJECT_KEY" "$FORCE"

zip_size="$(du -h "$LOCAL_PATH" | cut -f1)"
echo "uploading $zip_size -> $(r2_s3_uri "$OBJECT_KEY") ..."

aws s3 cp "$LOCAL_PATH" "$(r2_s3_uri "$OBJECT_KEY")" \
  --endpoint-url "$R2_ENDPOINT"

echo "uploaded $(r2_s3_uri "$OBJECT_KEY")"

if [[ -n "${R2_PUBLIC_BASE_URL:-}" ]]; then
  base="${R2_PUBLIC_BASE_URL%/}"
  echo "public: ${base}/${OBJECT_KEY}"
fi
