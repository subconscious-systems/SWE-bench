#!/usr/bin/env bash
# Idempotent instance setup via SSM: Docker, uv, /data volume, repo paths.
# Run after deploy.sh. Safe to re-run.
# Usage: ./infra/bootstrap.sh <stage>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

cloud_parse_stage "$0" "$@"
shift

require_aws
INSTANCE_ID="$(get_instance_id)"
echo "Running bootstrap on $INSTANCE_ID (stage=$STAGE) ..."
remote_bootstrap "$INSTANCE_ID"
check_runner_ready "$INSTANCE_ID"
echo "Bootstrap OK."
