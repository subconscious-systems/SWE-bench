#!/usr/bin/env bash
# Cloudflare R2 helpers. Source only.
#
# R2 credentials are NEVER exported into the environment — they are injected
# per-invocation via r2_aws(), so real-AWS calls later in the same shell keep
# working (the old r2-common.sh exported AWS_ACCESS_KEY_ID globally, which
# silently poisoned subsequent EC2/SSM calls).
set -euo pipefail

r2_ensure_tools() {
  local missing=()
  command -v zip >/dev/null 2>&1 || missing+=(zip)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v aws >/dev/null 2>&1 || missing+=(aws)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing tools: ${missing[*]} (instance: re-run swb bootstrap)" >&2
    exit 1
  fi
}

# Load R2_* config from an .env file into shell variables (NOT exported).
r2_load_env() {
  local env_file="${1:-}"
  if [[ -z "$env_file" ]]; then
    if [[ -f .env ]]; then
      env_file=".env"
    elif [[ -f mini-swe-runs/.env ]]; then
      env_file="mini-swe-runs/.env"
    else
      echo "error: .env not found (set R2_* vars for results push/restore)" >&2
      exit 1
    fi
  fi
  # Plain source (no set -a): vars stay shell-local, nothing leaks to children.
  # shellcheck disable=SC1090
  source "$env_file"

  : "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID required in .env}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required in .env}"
  : "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required in .env}"
  : "${R2_BUCKET:?R2_BUCKET required in .env}"

  R2_PREFIX="${R2_PREFIX:-swe-bench-runs}"
  R2_PREFIX="${R2_PREFIX#/}"
  R2_PREFIX="${R2_PREFIX%/}"
  R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
}

# Run aws against R2 with credentials scoped to this single invocation.
r2_aws() {
  env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
    aws --endpoint-url "$R2_ENDPOINT" "$@"
}

r2_zip_basename() {
  echo "swe-bench-${1}.zip"
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
  echo "s3://${R2_BUCKET}/${1}"
}

r2_object_exists() {
  r2_aws s3api head-object --bucket "$R2_BUCKET" --key "$1" >/dev/null 2>&1
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
