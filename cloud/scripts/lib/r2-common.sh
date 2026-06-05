#!/usr/bin/env bash
# Shared Cloudflare R2 helpers. Source only; do not execute directly.
set -euo pipefail

_R2_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

r2_ensure_tools() {
  if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    echo "error: zip/unzip not found; run ./infra/bootstrap.sh <stage>" >&2
    exit 1
  fi
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "$_R2_LIB_DIR/install-aws-cli.sh" ]]; then
    echo "AWS CLI not found; installing v2 ..."
    if [[ "$(id -u)" -eq 0 ]]; then
      bash "$_R2_LIB_DIR/install-aws-cli.sh"
    elif command -v sudo >/dev/null 2>&1; then
      sudo bash "$_R2_LIB_DIR/install-aws-cli.sh"
    else
      bash "$_R2_LIB_DIR/install-aws-cli.sh"
    fi
    return 0
  fi
  echo "error: aws cli not found; run ./infra/bootstrap.sh <stage>" >&2
  exit 1
}

r2_load_env() {
  local env_file="${1:-}"
  if [[ -z "$env_file" ]]; then
    if [[ -f .env ]]; then
      env_file=".env"
    elif [[ -f mini-swe-runs/.env ]]; then
      env_file="mini-swe-runs/.env"
    else
      echo "error: .env not found (set R2_* vars for upload/restore)" >&2
      exit 1
    fi
  fi
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a

  : "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID required in .env}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required in .env}"
  : "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required in .env}"
  : "${R2_BUCKET:?R2_BUCKET required in .env}"

  R2_PREFIX="${R2_PREFIX:-swe-bench-runs}"
  R2_PREFIX="${R2_PREFIX#/}"
  R2_PREFIX="${R2_PREFIX%/}"
  R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"

  export R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_PREFIX R2_ENDPOINT
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
}

r2_zip_basename() {
  local run_name="$1"
  echo "swe-bench-${run_name}.zip"
}

r2_object_key() {
  local run_name="$1"
  local zip_name
  zip_name="$(r2_zip_basename "$run_name")"
  if [[ -n "$R2_PREFIX" ]]; then
    echo "${R2_PREFIX}/${run_name}/${zip_name}"
  else
    echo "${run_name}/${zip_name}"
  fi
}

r2_s3_uri() {
  local key="$1"
  echo "s3://${R2_BUCKET}/${key}"
}

r2_object_exists() {
  local key="$1"
  aws s3api head-object \
    --bucket "$R2_BUCKET" \
    --key "$key" \
    --endpoint-url "$R2_ENDPOINT" \
    >/dev/null 2>&1
}

r2_confirm_overwrite() {
  local key="$1"
  local force="${2:-0}"
  if ! r2_object_exists "$key"; then
    return 0
  fi
  echo "warning: R2 object already exists: $(r2_s3_uri "$key")" >&2
  if [[ "$force" == "1" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -p "Overwrite? [y/N] " ans
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
    esac
  fi
  echo "error: re-run with --force to overwrite" >&2
  exit 1
}
