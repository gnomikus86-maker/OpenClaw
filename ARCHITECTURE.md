# Architecture

Why this bridge works the way it does. Read this if you want to debug or extend — it explains the non-obvious decisions.

## Components

```
┌─────────────────┐      HTTP/JSON       ┌──────────────────┐
│   Paperclip     │ ←──────────────────→ │   Paperclip DB   │
│  (orchestrator) │                      │  (embedded pg)   │
└────────┬────────┘                      └──────────────────┘
         │
         │ WebSocket (ws://127.0.0.1:18789)
         │ + Ed25519 device signature
         │ + auto-pair on first connect
         ▼
┌─────────────────┐
│ OpenClaw Gateway│  ← user systemd unit, RestartSec=5
│  (port 18789)   │
└────────┬────────┘
         │
         │ HTTPS / Bearer auth (OpenAI-compatible)
         ▼
┌─────────────────┐
│   wormsoft      │  (proxy, bundled with OpenClaw)
│  api.wormsoft.ru│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   MiniMax M3    │  (Chinese open-source LLM, marketed as GPT-5.x)
│  (the actual    │
│   model)        │
└─────────────────┘
```

Each box runs (or lives) on different infrastructure:

| Component | Where | Why |
|---|---|---|
| Paperclip | Same host as OpenClaw | Tight coupling, low latency |
| OpenClaw Gateway | Same host | localhost WebSocket is fast |
| wormsoft | cloud (wormsoft.ru) | You don't run this; it's a proxy |
| MiniMax M3 | cloud (China) | Open-source model hosted by wormsoft |

## The non-obvious decisions

### Why `disableDeviceAuth: false` (not true)

The Paperclip `openclaw_gateway` adapter has a `disableDeviceAuth` flag. Most walkthroughs online suggest `true` because the alternative throws errors like:

```
invalid connect params: device payload conflict
```

What those walkthroughs miss: with `disableDeviceAuth: true`, the adapter connects with **only** the bootstrap token. The OpenClaw gateway accepts it, but **doesn't bind any scopes to the connection**. The connection works for some read-only methods, but anything requiring `operator.write` (which is most of what an agent does — agent.run, agent.wait, anything with state changes) returns:

```
missing scope: operator.write
```

The fix: `disableDeviceAuth: false`. The adapter generates an Ed25519 keypair, signs each `connect` request with the device's private key, and the gateway runs an auto-pair flow:

```
adapter                         gateway
   │── connect (signed) ──────→ │
   │                            │── pair request created
   │←─ pairing required ────── │
   │── device.pair.list ──────→ │
   │←─ requestId ─────────────│
   │── device.pair.approve ───→│
   │←─ ok ─────────────────────│
   │── connect (signed) ──────→ │
   │←─ hello ok + scopes ─────│
```

The `autoPairOnFirstConnect: true` flag makes this automatic. The whole dance takes ~500ms.

After pair, the gateway stores the device's public key + scopes. **Future reconnects skip pair** and just sign+go.

### Why scopes-in-config don't help

Paperclip's adapter config has a `scopes` field. You might think:

```json
{ "scopes": ["operator.admin", "operator.write", "operator.read"] }
```

This would fix `missing scope: operator.write`, right? **No.** The adapter sends those scopes in the `connect.params.scopes` field, but the **gateway ignores client-claimed scopes** for trusted connections. It uses the scopes bound to the device at pair-time.

Source: `/usr/lib/node_modules/openclaw/dist/method-scopes-DOxx6FV1.js` defines `authorizeOperatorScopesForMethod`:

```js
function authorizeOperatorScopesForMethod(method, scopes) {
    if (scopes.includes("operator.admin")) return { allowed: true };
    // ...
}
```

This is the **client-side check** (used by the OpenClaw CLI to decide what it can do). The **gateway has its own equivalent** in `command-auth-BlBs2ty0.js`, and it doesn't trust client claims — it uses what was assigned at pair.

So `scopes` in Paperclip adapter config is a **lie we tell the adapter** (so it doesn't refuse to send the request), but the actual authorization happens server-side based on the device pair state.

### Why the bootstrap token alone isn't enough

You could create a long-lived "operator token" with all scopes through `openclaw devices rotate --scope operator.admin --scope operator.write --scope operator.read --role operator`. The command returns:

```json
{
  "deviceId": "...",
  "role": "operator",
  "token": "k5MBx5wfzSkGPVKU0YWz96-M98QjYMM9P8KpV-Qpa90",
  "scopes": ["operator.admin", "operator.approvals", "operator.pairing", "operator.read", "operator.write"]
}
```

Tempting. **Don't use it as `authToken` in Paperclip.** Why: this token is registered in the **device-pair store**, not in the **bootstrap token table** (`gateway.auth.token` in openclaw.json). The gateway checks against bootstrap table first, doesn't find it, returns `gateway token mismatch`.

Use this token via the `deviceToken` field, not `authToken`. Or stick with `authToken` + `disableDeviceAuth: false` and let the device auth path handle it.

### Why `local_trusted` mode for Paperclip

Paperclip has two main auth modes:

- `authenticated`: full better-auth, requires PostgreSQL (or you point at an external one), supports multi-tenant, sign-in/sign-up flows.
- `local_trusted`: implicit `local-board` user, embedded PostgreSQL, single-tenant, no sign-in.

The `local_trusted` mode avoids three bugs we hit with `authenticated`:

1. `sign-in/email 200 → get-session 401` (better-auth session not refreshing)
2. Needing to install/run PostgreSQL separately
3. Nginx reverse-proxy auth header passthrough issues

If you're running Paperclip for yourself (or a small team), `local_trusted` is enough. If you need multi-tenant or public sign-up, you'll have to migrate — and that's where the real bugs live.

### Why wormsoft is in the path

You have an OpenClaw subscription. OpenClaw's publisher (wormsoft) bundles an OpenAI-compatible proxy that routes to MiniMax M3 (their hosted model). This is what your subscription pays for.

So: OpenClaw sub → wormsoft API → MiniMax M3. You're already paying for the model; you just need to wire it up.

### Why not just talk to MiniMax directly?

You could. But:

- wormsoft handles auth, rate limits, billing, model selection
- Your OpenClaw subscription includes a wormsoft key with usage quota
- Direct MiniMax API access is via a different Chinese vendor (Aliyun, etc.) and may not be included

If you outgrow wormsoft, swap the `OPENAI_API_KEY` and `PAPERCLIP_CODEX_PROVIDERS` values in Paperclip's `.env` to point at any other OpenAI-compatible endpoint. The bridge doesn't care which model runs at the end.

## Failure modes

### "OpenClaw gateway isn't running"

Most common. Caused by:

- `loginctl enable-linger openclaw` not run → watchdog dies on logout
- A previous agent crash → user systemd didn't restart (rare; usually fine)
- Port 18789 in use by something else

Fix:

```bash
systemctl --user status openclaw-gateway.service
# If not active:
systemctl --user start openclaw-gateway.service
loginctl enable-linger openclaw  # do this once, forever
```

### "unauthorized: gateway token mismatch"

You wrote `$OC_TOKEN` in Paperclip config but `openclaw.json` has a different value. Fix: copy from one to the other.

### "missing scope: operator.write"

You set `disableDeviceAuth: true`. Change to `false`.

### "ECONNREFUSED 127.0.0.1:18789"

OpenClaw gateway is down. See first item.

### Model gives nonsense answers

You're on the wrong model or the proxy is misconfigured. Test direct:

```bash
curl -s https://ai.wormsoft.ru/api/gpt/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-5.2","messages":[{"role":"user","content":"Reply with: hello"}]}'
```

If that returns "hello", the model is fine and the issue is in Paperclip config. If it returns 4xx, your wormsoft key is bad.

## Performance notes

End-to-end latency from Paperclip issue creation → agent reply:

- Best case: ~25 seconds (model gives short answer, no retries)
- Typical: ~60 seconds (model thinks, tool calls, retries)
- Worst case: ~180 seconds (timeout)

Most of this is the model, not the bridge. The bridge adds ~100ms of WebSocket overhead.

## Extending

### Different model provider

Edit Paperclip's `.env`:

```bash
# Switch to any OpenAI-compatible endpoint
OPENAI_API_KEY=sk-your-key
PAPERCLIP_CODEX_PROVIDERS={"providers":{"myprovider":{"base_url":"https://api.example.com/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}}}
```

Restart Paperclip. The bridge doesn't change.

### Multi-agent

Create more agents via the same API, change the `name` field. Each gets its own session, but they share the OpenClaw gateway (which is fine — it's just WebSocket).

### Custom instructions per agent

Paperclip agents have `instructions` fields. The bridge passes them as the wake prompt. Configure via the UI or API:

```bash
curl -X PATCH http://127.0.0.1:3100/api/agents/$AGENT_ID \
  -H "Content-Type: application/json" \
  -d '{"instructions":"You are a helpful assistant who answers in haiku."}'
```

### Slack/Discord/Telegram notifications

Out of scope for the bridge. Paperclip has built-in cron for delivery, and you can wire any webhook. See Paperclip docs for `resultDelivery`.