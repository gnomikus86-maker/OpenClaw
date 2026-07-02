# Paperclip × OpenClaw Bridge

> Run a **Paperclip** AI agent that thinks through **MiniMax M3** (marketed as GPT-5.2)
> — using your existing OpenClaw subscription. **No extra OpenAI bill.**

[![status](https://img.shields.io/badge/status-working-brightgreen)]()
[![paperclip](https://img.shields.io/badge/paperclip-2026.626-purple)]()
[![openclaw](https://img.shields.io/badge/openclaw-2026.4.1-orange)]()
[![license](https://img.shields.io/badge/license-MIT-blue)]()
[![cost](https://img.shields.io/badge/cost-0%20%E2%82%BD%2Fmonth-success)]()

## What is this?

You have:

- **OpenClaw** — AI assistant CLI/Gateway (2500₽/month subscription, comes bundled with `wormsoft` proxy)
- **Paperclip** — self-hosted agent orchestrator (open-source)
- **wormsoft** — OpenAI-compatible proxy that routes to **MiniMax M3** (Chinese open-source model, marketed under GPT-5.x names, GPT-4o quality in practice)

You want: a Paperclip agent that actually works, runs MiniMax M3 under the hood, and costs you **nothing extra** beyond your existing OpenClaw sub.

This repo is the bridge that wires them together. It took us 14 hours of debugging and one server reboot to figure it out — now it's documented.

## Why bother?

| Alternative | Cost | Catch |
|---|---|---|
| OpenAI direct | $20+/month | You don't have a non-Russian card. |
| proxyapi.ru | 1500₽/month | Russian card only, yet another vendor. |
| **OpenClaw + wormsoft + MiniMax** | **0₽ extra** | The model is Chinese. Quality is GPT-4o-tier, not real GPT-5. |

If "good enough at GPT-4o quality" is fine for your agent tasks — this saves you 1500₽/month and avoids vendor lock-in.

## TL;DR

```bash
# 1. Install Paperclip (see INSTALL.md)
npm install -g @paperclipai/server
# ... configure local_trusted + bind loopback

# 2. Put your OpenClaw wormsoft key into Paperclip's .env
echo 'OPENAI_API_KEY=your-wormsoft-key-here' >> ~/.paperclip/.env
echo 'PAPERCLIP_CODEX_PROVIDERS={"providers":{"wormsoft":{"base_url":"https://ai.wormsoft.ru/api/gpt/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}}}' >> ~/.paperclip/.env

# 3. Create the bridge agent via Paperclip API (see INSTALL.md)
curl -X POST http://localhost:3100/api/companies/<COMPANY_ID>/agents \
  -H "Content-Type: application/json" \
  -d @examples/openclaw-bridge-agent.json

# 4. Trigger heartbeat
curl -X POST http://localhost:3100/api/agents/<AGENT_ID>/heartbeat/invoke

# 5. Create a test issue
curl -X POST http://localhost:3100/api/companies/<COMPANY_ID>/issues \
  -H "Content-Type: application/json" \
  -d '{"title":"Ping","description":"Reply with the current day of week.","status":"todo","assigneeAgentId":"<AGENT_ID>"}'

# 6. Wait ~60s. Watch the agent reply.
```

Full step-by-step in **[INSTALL.md](./INSTALL.md)**.

## What's in the box

- **[INSTALL.md](./INSTALL.md)** — full setup from zero, including Paperclip install + OpenClaw integration
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — how the bridge works, why device auth matters, why scopes-in-config don't help
- **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** — every error we hit and how to fix it (the real value here)
- **[examples/](./examples/)** — copy-paste JSON configs and env templates
- **[scripts/](./scripts/)** — automation helpers (heartbeat cron, health checks)

## What works

After ~1 hour of setup:

```
Paperclip issue "Тест: проверь, что ты на связи"
  ↓
OpenClaw-Bridge agent wakes up
  ↓
WebSocket connect to ws://127.0.0.1:18789
  ↓
OpenClaw Gateway routes to wormsoft
  ↓
MiniMax M3 ("GPT-5.2") replies
  ↓
Reply back to Paperclip issue
  ↓
Agent closes issue as done
```

Actual log from a real run:

> "Сейчас вторник (Tue 2026-06-30, 07:02 UTC), а 7*6 = 42. Handshake работает end-to-end: Paperclip → /api/issues/{id} → OpenClaw-Bridge (ws://127.0.0.1:18789, scopes: operator.admin/write/read) → wormsoft → MiniMax-M3."

## 📰 In the wild

- **Writeup on vc.ru** (2026-07-01): [«Запустил self-hosted AI-агента за вечер — и не заплатил OpenAI ни рубля»](https://vc.ru/ai/3006832-zapustil-self-hosted-ai-agenta-za-vecher-i-ne-zaplatil-openai-ni-rublya) — the story of how this whole stack came together in one evening.

## What doesn't work (yet)

- **CEO via `codex_local` adapter** — it's hard-coded to ChatGPT subscription auth. Use `openclaw_gateway` instead.
- **Auto heartbeat on schedule** — heartbeat works manually (`POST /heartbeat/invoke`); auto-schedule exists but is slow. Wrap it in cron for now.
- **Multi-tenant Paperclip** — `local_trusted` mode means single-tenant. For multi-tenant, use `authenticated` + bootstrap tokens properly.

See TROUBLESHOOTING.md for workarounds.

## Tested with

- Paperclip `2026.626.0`
- OpenClaw `2026.4.1`
- Ubuntu 24.04, Node 22
- OpenClaw Gateway running as `systemd --user` service with `enable-linger`

## License

MIT. Use it, fork it, sell services on top, whatever.

## Contributing

PRs welcome for:

- Real screenshots of Paperclip UI working with the bridge
- Working CEO-agent via a different adapter (so we have 2 paths)
- Multi-tenant `authenticated` mode documentation
- A proper Prometheus exporter for heartbeat health

## Money? 💰

This project saves 1500₽/month per user. If you're a freelancer / самозанятый:

- **Tier 1 (free)**: this repo. Set it up yourself in an hour.
- **Tier 2 (paid)**: someone sets it up for you. Reasonable rate: 5-10k₽ one-time.
- **Tier 3 (managed)**: hosted Paperclip + bridge for a monthly fee.

Contact: see USER.md in the workspace, or open an issue.

---

*"Why pay for OpenAI when your AI subscription already includes a working GPT-4o-tier model?"*