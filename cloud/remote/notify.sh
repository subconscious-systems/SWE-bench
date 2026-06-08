#!/usr/bin/env bash
# Post one Slack message to an incoming webhook. Used both on the instance
# (by run_job.sh) and locally (by swb snapshot-data).
#
# Usage: notify.sh <status> <job> <run_name> [message]
#   status: start | progress | success | failure
#
# Silent no-op when SLACK_WEBHOOK_URL is unset, and never fails the caller —
# a Slack outage must not break a benchmark or snapshot job.
set -uo pipefail

STATUS="${1:-}"
JOB="${2:-}"
RUN_NAME="${3:-}"
MESSAGE="${4:-}"

if [[ -z "$STATUS" || -z "$JOB" ]]; then
  echo "usage: notify.sh <start|progress|success|failure> <job> <run_name> [message]" >&2
  exit 2
fi

# Load .env for SLACK_WEBHOOK_URL if not already in the environment. Try the
# synced instance path first, then a local checkout.
if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  for envf in /opt/swe-bench/mini-swe-runs/.env "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../mini-swe-runs" 2>/dev/null && pwd)/.env"; do
    if [[ -n "$envf" && -f "$envf" ]]; then
      _v="$(grep -E '^SLACK_WEBHOOK_URL=' "$envf" | tail -1 | cut -d= -f2-)"
      _v="${_v%$'\r'}"                 # strip CRLF if the .env has Windows line endings
      _v="${_v#[\"\']}"; _v="${_v%[\"\']}"  # strip surrounding quotes
      if [[ -n "$_v" ]]; then SLACK_WEBHOOK_URL="$_v"; break; fi
    fi
  done
fi

# Not configured → nothing to do (success exit so callers don't trip set -e).
[[ -z "${SLACK_WEBHOOK_URL:-}" ]] && exit 0

STAGE="${SWB_STAGE:-}"
if [[ -z "$STAGE" && -f /opt/swe-bench/.swb-stage ]]; then
  STAGE="$(tr -d '[:space:]' < /opt/swe-bench/.swb-stage)"
fi
STAGE="${STAGE:-unknown}"

case "$STATUS" in
  start)    emoji="▶️"; color="#36c5f0" ;;
  progress) emoji="⏳"; color="#aaaaaa" ;;
  success)  emoji="✅"; color="good" ;;
  failure)  emoji="❌"; color="danger" ;;
  *)        emoji="•";  color="#aaaaaa" ;;
esac

title="${emoji}  ${STAGE} · ${JOB}${RUN_NAME:+ · ${RUN_NAME}}"

# Environment/footer line: instance id (IMDS, best-effort) + region + host.
iid=""
region=""
if command -v curl >/dev/null 2>&1; then
  token="$(curl -fsS -m 1 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    iid="$(curl -fsS -m 1 -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
    region="$(curl -fsS -m 1 -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)"
  fi
fi
footer="${iid:-$(hostname 2>/dev/null || echo local)}${region:+ · $region}"

# Top-level text pings the channel on failure (mentions inside attachments
# do not trigger notifications).
pretext=""
[[ "$STATUS" == "failure" ]] && pretext="<!here>"

# Build JSON safely: jq if available, else python3, else a minimal escape.
payload=""
if command -v jq >/dev/null 2>&1; then
  payload="$(jq -n \
    --arg text "$pretext" \
    --arg color "$color" \
    --arg title "$title" \
    --arg msg "$MESSAGE" \
    --arg footer "$footer" \
    '{text: $text, attachments: [{color: $color, title: $title, text: $msg, footer: $footer}]}')"
elif command -v python3 >/dev/null 2>&1; then
  payload="$(python3 -c '
import json, sys
text, color, title, msg, footer = sys.argv[1:6]
print(json.dumps({"text": text, "attachments": [{"color": color, "title": title, "text": msg, "footer": footer}]}))
' "$pretext" "$color" "$title" "$MESSAGE" "$footer")"
else
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  payload="{\"text\":\"$(esc "$pretext")\",\"attachments\":[{\"color\":\"$(esc "$color")\",\"title\":\"$(esc "$title")\",\"text\":\"$(esc "$MESSAGE")\",\"footer\":\"$(esc "$footer")\"}]}"
fi

curl -fsS -m 10 -X POST -H 'Content-type: application/json' \
  --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
exit 0
