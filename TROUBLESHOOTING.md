# Troubleshooting

Every error we hit while building this, what caused it, and how to fix it. If something doesn't work for you, look here first.

---

## OpenClaw gateway

### `gateway token mismatch (provide gateway auth token)`

**What you see** (in Paperclip agent status):
```json
{ "status": "error", "errorReason": "unauthorized: gateway token mismatch (provide gateway auth token)" }
```

**Cause**: the `authToken` in Paperclip agent config doesn't match `gateway.auth.token` in `~/.openclaw/openclaw.json`.

**Fix**:
```bash
# Get the token OpenClaw expects:
OC_TOKEN=$(python3 -c "import json; print(json.load(open('/home/openclaw/.openclaw/openclaw.json'))['gateway']['auth']['token'])")
echo "OpenClaw expects: $OC_TOKEN"

# Update Paperclip agent:
curl -X PATCH http://127.0.0.1:3100/api/agents/$AGENT_ID \
  -H "Content-Type: application/json" \
  -d "{\"adapterConfig\": {\"authToken\": \"$OC_TOKEN\"}}"
```

Or do the reverse: edit `~/.openclaw/openclaw.json` and set `gateway.auth.token` to whatever Paperclip has. The first way is cleaner.

---

### `missing scope: operator.write`

**What you see**:
```json
{ "errorReason": "missing scope: operator.write" }
```

**Cause**: `disableDeviceAuth: true` in Paperclip adapter config. The gateway accepts the connection (token matches) but doesn't bind any scopes.

**Fix**:
```bash
curl -X PATCH http://127.0.0.1:3100/api/agents/$AGENT_ID \
  -H "Content-Type: application/json" \
  -d '{"adapterConfig": {"disableDeviceAuth": false}}'

# Then trigger heartbeat:
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}'
```

Don't add `scopes` to `adapterConfig`. They're ignored by the gateway (see [ARCHITECTURE.md](./ARCHITECTURE.md)).

---

### `connect ECONNREFUSED 127.0.0.1:18789`

**What you see**:
```json
{ "errorReason": "connect ECONNREFUSED 127.0.0.1:18789" }
```

**Cause**: OpenClaw gateway isn't listening.

**Fix**:
```bash
systemctl --user status openclaw-gateway.service
# If "inactive (dead)":
systemctl --user start openclaw-gateway.service

# If still won't start:
sudo -n /usr/bin/journalctl -u openclaw-gateway.service -n 30 --no-pager
```

If it complains "another gateway instance is already listening" — kill the orphan:
```bash
ps -ef | grep openclaw-gateway | grep -v grep
sudo -n /usr/bin/kill -9 <orphan-PID>
systemctl --user start openclaw-gateway.service
```

---

### Gateway runs for ~1 hour then dies

**Cause**: user systemd dies when the user logs out, and `enable-linger` wasn't set.

**Fix** (one-time, forever):
```bash
loginctl enable-linger openclaw
```

Verify:
```bash
loginctl show-user openclaw | grep Linger
# Should show: Linger=yes
```

---

### `user@<uid>.service` not running

You see `Failed to connect to bus` when running `systemctl --user status`.

**Cause**: you SSH'd in but `pam_systemd` didn't start a user session (rare with normal SSH; common with `su` or non-interactive logins).

**Fix**:
```bash
# Check session:
loginctl list-sessions | grep openclaw
# If empty:
loginctl enable-linger openclaw
# Re-login or:
sudo loginctl activate-user openclaw
```

---

## Paperclip

### `sign-in/email 200 → get-session 401`

**What you see**: you log into the Paperclip UI, get redirected to dashboard, dashboard calls `/api/auth/get-session`, gets 401.

**Cause**: Paperclip's `authenticated` mode with better-auth has a known session-refresh bug.

**Fix**: switch to `local_trusted` mode. Edit `~/.paperclip/.env`:

```bash
PAPERCLIP_DEPLOYMENT_MODE=local_trusted
BIND=loopback
```

Restart Paperclip:
```bash
sudo systemctl restart paperclip.service
```

You'll get an implicit `local-board` user — no sign-in needed. If you want real auth, see Paperclip's better-auth docs (and budget a day for debugging).

---

### Paperclip service won't start: `embedded postgres already exists`

**What you see**:
```
Embedded PostgreSQL cluster already exists; skipping init
```
followed by startup hang.

**Cause**: stale lockfile or corrupted embedded DB. Usually after a hard kill.

**Fix**:
```bash
sudo systemctl stop paperclip.service
# Don't delete the DB! Just remove the lock:
sudo rm /home/openclaw/paperclip/data/postmaster.pid 2>/dev/null
sudo systemctl start paperclip.service
```

If still broken, check disk space (`df -h /`). Embedded postgres refuses to start if it can't write to WAL.

---

### `heartbeat.enabled = true` but no heartbeat fires

**Cause**: known issue with Paperclip 2026.626.0. Auto-heartbeat is slow (5+ minute lag) and sometimes doesn't fire if there's no on-demand trigger.

**Fix**: use manual invoke in cron:
```bash
cat > ~/heartbeat-cron.sh <<EOF
#!/bin/bash
AGENT_ID="\$1"
[ -z "\$AGENT_ID" ] && { echo "Usage: \$0 <agent-id>"; exit 1; }
curl -sf -X POST http://127.0.0.1:3100/api/agents/\$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}' > /dev/null
EOF
chmod +x ~/heartbeat-cron.sh

# Every 5 minutes
crontab - <<EOF
*/5 * * * * /home/openclaw/heartbeat-cron.sh $AGENT_ID
EOF
```

---

### Agent stays in `status: error` after fixing the cause

**Cause**: Paperclip caches error state until next heartbeat.

**Fix**:
```bash
# Trigger heartbeat
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke

# Wait 10-30 seconds, then check:
curl -s http://127.0.0.1:3100/api/agents/$AGENT_ID | python3 -m json.tool | grep -E 'status|errorReason'
```

---

## Wormsoft / model

### `invalid API key` from wormsoft

**Cause**: your wormsoft key expired or was revoked.

**Fix**:
1. Log into your OpenClaw dashboard
2. Find the wormsoft API key section
3. Regenerate
4. Update Paperclip `.env`:
   ```bash
   sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$NEW_KEY/" ~/paperclip/.env
   sudo systemctl restart paperclip.service
   ```

### Model returns 429 (rate limit)

**Cause**: you exceeded wormsoft's free tier quota.

**Fix**:
- Wait an hour
- Or upgrade your wormsoft plan via OpenClaw dashboard
- Or switch to a different provider (see ARCHITECTURE.md → Extending)

### Model gives nonsense answers in Russian

**Cause**: MiniMax M3 is fine in English, mediocre in Russian. It's a Chinese model with mostly English training.

**Fix**: don't ask it Russian-specific questions for now. Or switch to a different model via Paperclip config.

---

## GitHub publishing

### "Permission denied" pushing to GitHub

**Cause**: wrong token scopes. Fine-grained PAT needs `Contents: Read+Write` and `Metadata: Read`. Classic PAT needs `repo`.

**Fix**: regenerate at https://github.com/settings/tokens with the right scopes.

### "Repository not found" despite correct URL

**Cause**: you created a fine-grained PAT scoped to specific repos, and didn't include the new repo.

**Fix**: edit the PAT, add the repo to "Repository access" → "Only select repositories".

---

## When in doubt

1. Check `journalctl` for the relevant service: `journalctl -u paperclip.service -n 100 --no-pager` or `journalctl --user -u openclaw-gateway.service -n 100 --no-pager`
2. Test OpenClaw gateway directly: `openclaw gateway call health`
3. Test Paperclip API: `curl http://127.0.0.1:3100/api/health`
4. Test wormsoft directly: see ARCHITECTURE.md → "Model gives nonsense answers"

If none of those reveal the problem, open an issue on GitHub with logs from all three.