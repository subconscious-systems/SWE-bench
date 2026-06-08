#!/usr/bin/env bash
# Authenticate this instance to Docker Hub so eval-image pulls aren't subject
# to anonymous rate limits (429s). Reads DOCKERHUB_USER / DOCKERHUB_TOKEN from
# mini-swe-runs/.env (use a read-only Personal Access Token, not a password).
#
# Runs as the invoking user (ubuntu) — the agent and the eval harness pull
# through the docker daemon using ~/.docker/config.json, which persists on the
# root volume across reboots. No-op + exit 0 if creds are absent.
set -uo pipefail

ENV_FILE="${1:-/opt/swe-bench/mini-swe-runs/.env}"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../mini-swe-runs" 2>/dev/null && pwd)/.env"

read_var() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/\r$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

USER_VAL="${DOCKERHUB_USER:-$(read_var DOCKERHUB_USER)}"
TOKEN_VAL="${DOCKERHUB_TOKEN:-$(read_var DOCKERHUB_TOKEN)}"

if [[ -z "$USER_VAL" || -z "$TOKEN_VAL" ]]; then
  echo "docker-login: DOCKERHUB_USER/DOCKERHUB_TOKEN not set — skipping (pulls will be anonymous, rate-limited)"
  exit 0
fi

if printf '%s' "$TOKEN_VAL" | docker login -u "$USER_VAL" --password-stdin >/dev/null 2>&1; then
  echo "docker-login: authenticated to Docker Hub as $USER_VAL (auth persists in ~/.docker/config.json)"
else
  echo "docker-login: WARNING — docker login failed for $USER_VAL (check the token); pulls fall back to anonymous" >&2
  exit 0
fi
