# Installation Guide

Step-by-step setup from a clean Ubuntu 24.04 server (or any Linux with Node 22) to a fully working Paperclip + OpenClaw + wormsoft bridge. Expect ~60 minutes if nothing breaks.

## 0. Prerequisites

You need:

- **OpenClaw subscription** (2500₽/month). Includes a wormsoft API key. Get yours at `https://wormsoft.ru` or via your OpenClaw dashboard.
- **Ubuntu 24.04** server (or similar) with sudo access.
- **Node 22+** and **npm 10+**.
- A non-root user (`openclaw` in this guide — replace with your own).

```bash
# As root, or with sudo:
useradd -m -s /bin/bash openclaw
echo 'openclaw ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/tee, /usr/bin/fail2ban-client, /usr/bin/pkill, /usr/bin/kill, /usr/sbin/ss, /usr/bin/journalctl, /usr/bin/ps' >> /etc/sudoers.d/openclaw
# (Optional — adjust scope to taste. The key ones are systemctl, kill, ps, ss.)

su - openclaw
```

## 1. Install OpenClaw

OpenClaw is the AI gateway that bridges everything. It installs as a global npm package.

```bash
sudo npm install -g openclaw
# Verify:
openclaw --version
# Should print: 2026.4.1 (or newer)
```

OpenClaw ships with a built-in watchdog (user-level systemd unit). Make it survive reboots without an interactive login:

```bash
loginctl enable-linger openclaw
```

Verify the watchdog is running:

```bash
systemctl --user status openclaw-gateway.service
# Expected: Active: active (running)
```

> **Why this matters:** without `enable-linger`, the watchdog dies on logout. We've debugged this exact failure at 3am. Don't skip it.

## 2. Configure OpenClaw

The wizard generates `~/.openclaw/openclaw.json` on first run. If you've already used OpenClaw, this file exists.

```bash
openclaw configure
# Follow the prompts. At minimum set:
# - Gateway mode: local
# - Port: 18789
# - Auth: token
# - Token: pick a strong random string, save it as $OC_TOKEN
```

Or manually edit `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "auth": { "mode": "token", "token": "$OC_TOKEN" }
  }
}
```

Replace `$OC_TOKEN` with a strong random string (e.g., `openssl rand -hex 32`).

## 3. Test the OpenClaw gateway

```bash
# Restart to pick up config
openclaw gateway restart
sleep 3

# Probe
openclaw gateway call health
# Expected: ok
```

## 4. Install Paperclip

Paperclip is the agent orchestrator. It's a Node.js server with embedded PostgreSQL.

```bash
sudo npm install -g @paperclipai/server
# Verify:
paperclip --version
# Should print: @paperclipai/server 2026.626.0 (or newer)
```

### 4.1 Configure Paperclip for `local_trusted` mode

This is the **key trick** that avoids the `sign-in/email 200 → get-session 401` loop. `local_trusted` mode gives you an implicit `local-board` session without needing better-auth or external PostgreSQL.

```bash
mkdir -p ~/paperclip
cd ~/paperclip

cat > .env <<EOF
PAPERCLIP_DEPLOYMENT_MODE=local_trusted
BIND=loopback
PORT=3100

# OpenAI-compatible proxy to wormsoft (MiniMax M3)
OPENAI_API_KEY=$YOUR_WORMSOFT_KEY_HERE
PAPERCLIP_CODEX_PROVIDERS={"providers":{"wormsoft":{"base_url":"https://ai.wormsoft.ru/api/gpt/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}},"model_provider":"wormsoft"}
EOF
chmod 600 .env
```

Replace `$YOUR_WORMSOFT_KEY_HERE` with your actual wormsoft key. Get it from your OpenClaw dashboard or by emailing wormsoft support.

### 4.2 systemd unit for Paperclip

```bash
sudo tee /etc/systemd/system/paperclip.service > /dev/null <<'EOF'
[Unit]
Description=Paperclip AI Server
After=network.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw/paperclip
ExecStart=/usr/bin/node /usr/lib/node_modules/@paperclipai/server/dist/index.js
Restart=on-failure
RestartSec=5
EnvironmentFile=/home/openclaw/paperclip/.env

NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/home/openclaw/paperclip /tmp /var/tmp

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now paperclip.service
sleep 5

# Verify
curl http://127.0.0.1:3100/api/health
# Expected: {"status":"ok",...}
```

### 4.3 Optional: nginx reverse proxy

If you want to access Paperclip from outside the box:

```nginx
# /etc/nginx/sites-available/paperclip.conf
server {
    listen 80;
    server_name paperclip.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/paperclip.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

## 5. Create the OpenClaw-Bridge agent

This is the bridge agent that talks to OpenClaw gateway, which routes to wormsoft/MiniMax.

### 5.1 Get your company ID

```bash
COMPANY_ID=$(curl -s http://127.0.0.1:3100/api/companies | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "Company ID: $COMPANY_ID"
```

In `local_trusted` mode this works without auth. In `authenticated` mode you'd need a bearer token — see Paperclip docs.

### 5.2 Create the agent

```bash
curl -s -X POST http://127.0.0.1:3100/api/companies/$COMPANY_ID/agents \
  -H "Content-Type: application/json" \
  -d @examples/openclaw-bridge-agent.json
```

The JSON in `examples/openclaw-bridge-agent.json` should look like:

```json
{
  "name": "OpenClaw-Bridge",
  "role": "engineer",
  "capabilities": "general-purpose",
  "adapterType": "openclaw_gateway",
  "adapterConfig": {
    "url": "ws://127.0.0.1:18789",
    "authToken": "$OC_TOKEN",
    "disableDeviceAuth": false,
    "autoPairOnFirstConnect": true,
    "sessionKeyStrategy": "issue",
    "waitTimeoutMs": 120000,
    "timeoutSec": 180
  },
  "runtimeConfig": {
    "heartbeat": { "enabled": true, "cooldownSec": 10, "intervalSec": 300 }
  }
}
```

> **Critical:** `disableDeviceAuth: false` is non-obvious. Many guides say to set it `true` to avoid "device payload conflict" errors. Don't. With `false`, the adapter generates an Ed25519 device keypair and signs each connect — this is the path that grants scopes on the gateway side. See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full story.

Save the returned agent ID:

```bash
AGENT_ID=$(curl -s http://127.0.0.1:3100/api/companies/$COMPANY_ID/agents | \
  python3 -c "import sys,json; print([a['id'] for a in json.load(sys.stdin) if a['name']=='OpenClaw-Bridge'][0])")
echo "Agent ID: $AGENT_ID"
```

## 6. Trigger heartbeat manually

Auto-heartbeat is flaky in current Paperclip versions. Trigger one manually to verify the handshake:

```bash
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}'
```

Watch the agent status:

```bash
sleep 10
curl -s http://127.0.0.1:3100/api/agents/$AGENT_ID | python3 -m json.tool
```

Expected output (eventually):

```json
{
  "status": "idle",
  "errorReason": null,
  "lastHeartbeatAt": "2026-06-30T07:02:23.000Z"
}
```

If you see `errorReason: connect ECONNREFUSED 127.0.0.1:18789`, the OpenClaw gateway isn't running — go back to step 3.

If you see `errorReason: unauthorized: gateway token mismatch`, your `$OC_TOKEN` in step 5 doesn't match `openclaw.json` — fix it.

## 7. Create a test issue

This is the end-to-end check. The agent should wake up, route through OpenClaw → wormsoft → MiniMax, and reply.

```bash
curl -X POST http://127.0.0.1:3100/api/companies/$COMPANY_ID/issues \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Sanity check",
    "description": "Reply with the current day of week and 7*6. If you read this through wormsoft/MiniMax, the bridge is working.",
    "status": "todo",
    "priority": "medium",
    "assigneeAgentId": "'$AGENT_ID'"
  }'
```

Wait ~60 seconds, then check the issue:

```bash
ISSUE_ID=$(curl -s http://127.0.0.1:3100/api/companies/$COMPANY_ID/issues | \
  python3 -c "import sys,json; print([i['id'] for i in json.load(sys.stdin) if i['title']=='Sanity check'][0])")

curl -s http://127.0.0.1:3100/api/issues/$ISSUE_ID/comments | python3 -m json.tool
```

Expected: comments from the agent with a real answer (not "I can't reach the model", not "permission denied").

## 8. (Optional) Set up cron heartbeat

Auto-heartbeat in Paperclip is slow. Wrap manual invoke in cron:

```bash
cat > ~/heartbeat-cron.sh <<'EOF'
#!/bin/bash
AGENT_ID="your-agent-id-here"
curl -sf -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}' > /dev/null
EOF
chmod +x ~/heartbeat-cron.sh

# Every 5 minutes
crontab - <<'EOF'
*/5 * * * * /home/openclaw/heartbeat-cron.sh
EOF
```

## 9. Done

You now have:
- Paperclip running with local_trusted auth (no external DB)
- OpenClaw gateway with watchdog (survives reboot)
- A bridge agent that answers through MiniMax M3 via wormsoft
- Total cost: your existing OpenClaw subscription. **0 extra rubles.**

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the design rationale and [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for the bugs we hit.