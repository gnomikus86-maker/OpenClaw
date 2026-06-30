#!/usr/bin/env bash
# End-to-end smoke test for the bridge.
# Creates a test issue, waits for the agent to reply, checks the reply is sane.

set -euo pipefail

PAPERCLIP_URL="${PAPERCLIP_URL:-http://127.0.0.1:3100}"
COMPANY_ID="${COMPANY_ID:-}"
AGENT_ID="${AGENT_ID:-}"

if [ -z "$COMPANY_ID" ] || [ -z "$AGENT_ID" ]; then
  echo "Usage: COMPANY_ID=... AGENT_ID=... $0" >&2
  exit 1
fi

echo "[1/3] creating test issue..."
ISSUE=$(curl -sf -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/issues" \
  -H "Content-Type: application/json" \
  -d "{
    \"title\": \"Smoke test\",
    \"description\": \"Reply with the current day of week and 7*6.\",
    \"status\": \"todo\",
    \"priority\": \"medium\",
    \"assigneeAgentId\": \"$AGENT_ID\"
  }")
ISSUE_ID=$(echo "$ISSUE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  issue: $ISSUE_ID"

echo "[2/3] triggering heartbeat..."
curl -sf -X POST "$PAPERCLIP_URL/api/agents/$AGENT_ID/heartbeat/invoke" \
  -H "Content-Type: application/json" -d '{}' > /dev/null
echo "  ok"

echo "[3/3] waiting up to 90s for agent reply..."
for i in $(seq 1 18); do
  sleep 5
  STATUS=$(curl -sf "$PAPERCLIP_URL/api/issues/$ISSUE_ID" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  if [ "$STATUS" = "done" ]; then
    echo "  ✅ issue closed as done after ~$((i*5))s"
    exit 0
  fi
done

echo "  ❌ issue still $STATUS after 90s"
exit 1