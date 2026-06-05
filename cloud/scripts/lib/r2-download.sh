#!/usr/bin/env bash
# Download a file from Cloudflare R2.
#
# Usage: r2-download.sh <OBJECT_KEY> <LOCAL_PATH>
#   Loads R2_* from .env in cwd (or mini-swe-runs/.env).
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=r2-common.sh
source "$LIB_DIR/r2-common.sh"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <OBJECT_KEY> <LOCAL_PATH>" >&2
  exit 2
fi

OBJECT_KEY="$1"
LOCAL_PATH="$2"

r2_ensure_tools
r2_load_env

mkdir -p "$(dirname "$LOCAL_PATH")"

echo "downloading $(r2_s3_uri "$OBJECT_KEY") ..."
if ! aws s3 cp "$(r2_s3_uri "$OBJECT_KEY")" "$LOCAL_PATH" \
  --endpoint-url "$R2_ENDPOINT"; then
  echo "error: object not found: $(r2_s3_uri "$OBJECT_KEY")" >&2
  echo "  check RUN_NAME, R2_PREFIX, and R2_BUCKET in .env" >&2
  exit 1
fi

echo "downloaded $(r2_s3_uri "$OBJECT_KEY") -> $LOCAL_PATH"
