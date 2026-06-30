#!/usr/bin/env bash
# Heartbeat cron helper.
# Usage: heartbeat-cron.sh <agent-id>
# Schedule via crontab: */5 * * * * /path/to/heartbeat-cron.sh <agent-id>

set -euo pipefail

AGENT_ID="${1:-}"
PAPERCLIP_URL="${PAPERCLIP_URL:-http://127.0.0.1:3100}"

if [ -z "$AGENT_ID" ]; then
  echo "Usage: $0 <agent-id>" >&2
  exit 1
fi

# Trigger heartbeat. Silent on success, log on failure.
if ! curl -sf -X POST "$PAPERCLIP_URL/api/agents/$AGENT_ID/heartbeat/invoke" \
    -H "Content-Type: application/json" \
    -d '{}' > /dev/null; then
  echo "[$(date -u +%FT%TZ)] heartbeat failed for $AGENT_ID" >&2
  exit 1
fi