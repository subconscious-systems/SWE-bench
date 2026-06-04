#!/usr/bin/env bash
# Upload a file to Cloudflare R2 via S3-compatible API. Sources .env for credentials.
# Usage: r2-upload.sh <local-file> <s3-key>
set -euo pipefail

LOCAL_FILE="${1:?file}"
S3_KEY="${2:?key}"

if [[ -f .env ]]; then set -a; source .env; set +a; fi

: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID in .env}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID in .env}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY in .env}"
: "${R2_BUCKET:?set R2_BUCKET in .env}"

R2_PREFIX="${R2_PREFIX:-swe-bench-runs}"
ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

FULL_KEY="${R2_PREFIX%/}/${S3_KEY}"
DEST="s3://${R2_BUCKET}/${FULL_KEY}"

command -v aws >/dev/null || { echo "error: aws cli required" >&2; exit 1; }

aws s3 cp "$LOCAL_FILE" "$DEST" --endpoint-url "$ENDPOINT"
echo "Uploaded: $DEST"
if [[ -n "${R2_PUBLIC_BASE_URL:-}" ]]; then
  echo "URL: ${R2_PUBLIC_BASE_URL%/}/${FULL_KEY}"
fi
