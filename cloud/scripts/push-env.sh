#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

ENV_LOCAL="$REPO_ROOT/mini-swe-runs/.env"
ENV_EXAMPLE="$REPO_ROOT/mini-swe-runs/.env.example"

DRY_RUN=0
DIFF_KEYS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --diff) DIFF_KEYS=1 ;;
  esac
done

[[ -f "$ENV_LOCAL" ]] || {
  echo "error: $ENV_LOCAL not found (cp $ENV_EXAMPLE .env and fill in keys)" >&2
  exit 1
}

require_aws
REMOTE_ENV="$MINI_SWE_RUNS_PATH/.env"

if [[ "$DIFF_KEYS" == "1" ]]; then
  echo "Local keys:"
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_LOCAL" | cut -d= -f1 | sort
  echo "Remote keys:"
  ssh_cmd "grep -E '^[A-Za-z_][A-Za-z0-9_]*=' '$REMOTE_ENV' 2>/dev/null | cut -d= -f1 | sort" || echo "(no remote .env)"
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Would copy $ENV_LOCAL -> $REMOTE_ENV"
  exit 0
fi

TMP="$(mktemp)"
cp "$ENV_LOCAL" "$TMP"
chmod 600 "$TMP"
scp_to_remote "$TMP" "$REMOTE_ENV"
rm -f "$TMP"

ssh_cmd "chmod 600 '$REMOTE_ENV' && test -f '$REMOTE_ENV' && grep -qE '^(QWEN_API_KEY|OPENAI_API_KEY)=.' '$REMOTE_ENV'"
echo "Pushed .env to $REMOTE_ENV (API key present)."
