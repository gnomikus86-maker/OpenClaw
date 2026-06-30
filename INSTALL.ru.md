# Установка

Пошагово: с чистого Ubuntu 24.04 (или любой Linux с Node 22) до полностью рабочего Paperclip + OpenClaw + wormsoft моста. По времени — около часа, если ничего не ломается по дороге.

## 0. Что понадобится

- **Подписка OpenClaw** (2500₽/мес). В неё входит wormsoft API-ключ. Получи свой на `https://wormsoft.ru` или в личном кабинете OpenClaw.
- **Ubuntu 24.04** (или любой современный Linux) с sudo.
- **Node 22+** и **npm 10+**.
- Непривилегированный пользователь (в этом гайде — `openclaw`; замени на своё имя).

```bash
# от root или sudo:
useradd -m -s /bin/bash openclaw
echo 'openclaw ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/tee, /usr/bin/fail2ban-client, /usr/bin/pkill, /usr/bin/kill, /usr/sbin/ss, /usr/bin/journalctl, /usr/bin/ps' >> /etc/sudoers.d/openclaw
# (Опционально — подкрути под себя. Главное: systemctl, kill, ps, ss.)

su - openclaw
```

## 1. Установка OpenClaw

OpenClaw — это AI-шлюз, через который всё идёт. Ставится как глобальный npm-пакет.

```bash
sudo npm install -g openclaw
# Проверка:
openclaw --version
# Должно вывести: 2026.4.1 (или новее)
```

У OpenClaw есть встроенный watchdog (user-level systemd unit). Чтобы он переживал ребут без интерактивного входа:

```bash
loginctl enable-linger openclaw
```

Проверь, что watchdog запущен:

```bash
systemctl --user status openclaw-gateway.service
# Должно быть: Active: active (running)
```

> **Почему это важно:** без `enable-linger` watchdog умирает при выходе из сессии. Мы это словили в 3 часа ночи. Не пропусти.

## 2. Настройка OpenClaw

В первый запуск мастер создаст `~/.openclaw/openclaw.json`. Если ты уже пользуешься OpenClaw — файл уже есть.

```bash
openclaw configure
# По подсказкам. Минимум:
# - Gateway mode: local
# - Port: 18789
# - Auth: token
# - Token: случайная строка, сохрани как $OC_TOKEN
```

Или руками поправь `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "auth": { "mode": "token", "token": "$OC_TOKEN" }
  }
}
```

Замени `$OC_TOKEN` на случайную строку (например, `openssl rand -hex 32`).

## 3. Проверка OpenClaw gateway

```bash
# Перезапусти, чтобы подхватить конфиг
openclaw gateway restart
sleep 3

# Проверка
openclaw gateway call health
# Должно вернуть: ok
```

## 4. Установка Paperclip

Paperclip — это оркестратор агентов. Node.js-сервер с встроенным PostgreSQL.

```bash
sudo npm install -g @paperclipai/server
# Проверка:
paperclip --version
# Должно быть: @paperclipai/server 2026.626.0 (или новее)
```

### 4.1 Режим `local_trusted` для Paperclip

Это **ключевой трюк**, который обходит баг `sign-in/email 200 → get-session 401`. В режиме `local_trusted` ты получаешь неявную сессию `local-board` без better-auth и без внешнего PostgreSQL.

```bash
mkdir -p ~/paperclip
cd ~/paperclip

cat > .env <<EOF
PAPERCLIP_DEPLOYMENT_MODE=local_trusted
BIND=loopback
PORT=3100

# OpenAI-совместимый прокси в wormsoft (MiniMax M3)
OPENAI_API_KEY=$YOUR_WORMSOFT_KEY
PAPERCLIP_CODEX_PROVIDERS={"providers":{"wormsoft":{"base_url":"https://ai.wormsoft.ru/api/gpt/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}},"model_provider":"wormsoft"}
EOF
chmod 600 .env
```

Замени `$YOUR_WORMSOFT_KEY` на свой настоящий wormsoft-ключ (из личного кабинета OpenClaw).

### 4.2 systemd unit для Paperclip

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

# Проверка
curl http://127.0.0.1:3100/api/health
# Должно вернуть: {"status":"ok",...}
```

### 4.3 (Опционально) nginx reverse proxy

Если хочешь заходить в Paperclip снаружи:

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

## 5. Создаём OpenClaw-Bridge агента

Это и есть мост: агент, который разговаривает с OpenClaw gateway, а тот маршрутизирует в wormsoft/MiniMax.

### 5.1 Получи company ID

```bash
COMPANY_ID=$(curl -s http://127.0.0.1:3100/api/companies | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "Company ID: $COMPANY_ID"
```

В режиме `local_trusted` это работает без авторизации. В `authenticated` нужен bearer-токен — см. доку Paperclip.

### 5.2 Создай агента

```bash
curl -s -X POST http://127.0.0.1:3100/api/companies/$COMPANY_ID/agents \
  -H "Content-Type: application/json" \
  -d @examples/openclaw-bridge-agent.json
```

JSON в `examples/openclaw-bridge-agent.json` должен выглядеть так:

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

> **Важно:** `disableDeviceAuth: false` — это неочевидно. Большинство гайдов советуют ставить `true` чтобы избежать ошибок «device payload conflict». Не надо. С `false` адаптер генерит Ed25519 ключ и подписывает каждый connect — это и есть путь, по которому gateway выдаёт scopes. Подробности в [ARCHITECTURE.md](./ARCHITECTURE.md).

Сохрани ID агента:

```bash
AGENT_ID=$(curl -s http://127.0.0.1:3100/api/companies/$COMPANY_ID/agents | \
  python3 -c "import sys,json; print([a['id'] for a in json.load(sys.stdin) if a['name']=='OpenClaw-Bridge'][0])")
echo "Agent ID: $AGENT_ID"
```

## 6. Триггерни heartbeat вручную

Авто-heartbeat в текущей версии Paperclip работает медленно. Триггерни руками, чтобы убедиться, что handshake проходит:

```bash
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}'
```

Через 10 секунд смотри статус:

```bash
sleep 10
curl -s http://127.0.0.1:3100/api/agents/$AGENT_ID | python3 -m json.tool
```

Должно быть:

```json
{
  "status": "idle",
  "errorReason": null,
  "lastHeartbeatAt": "2026-06-30T07:02:23.000Z"
}
```

Если видишь `errorReason: connect ECONNREFUSED 127.0.0.1:18789` — OpenClaw gateway не запущен, вернись к шагу 3.

Если видишь `errorReason: unauthorized: gateway token mismatch` — токен `$OC_TOKEN` в шаге 5 не совпадает с `openclaw.json`. Поправь.

## 7. Создай тестовый issue

Это финальная проверка end-to-end. Агент должен проснуться, маршрутизировать через OpenClaw → wormsoft → MiniMax, и ответить.

```bash
curl -X POST http://127.0.0.1:3100/api/companies/$COMPANY_ID/issues \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Smoke test",
    "description": "Ответь: какой сегодня день недели и сколько будет 7*6? Если читаешь это через wormsoft/MiniMax — мост работает.",
    "status": "todo",
    "priority": "medium",
    "assigneeAgentId": "'$AGENT_ID'"
  }'
```

Подожди ~60 секунд, проверь issue:

```bash
ISSUE_ID=$(curl -s http://127.0.0.1:3100/api/companies/$COMPANY_ID/issues | \
  python3 -c "import sys,json; print([i['id'] for i in json.load(sys.stdin) if i['title']=='Smoke test'][0])")

curl -s http://127.0.0.1:3100/api/issues/$ISSUE_ID/comments | python3 -m json.tool
```

Ожидаемо: комментарии от агента с реальным ответом. Не «permission denied», не «I can't reach the model».

## 8. (Опционально) Heartbeat в cron

Авто-heartbeat в Paperclip медленный. Оберни manual invoke в cron:

```bash
cat > ~/heartbeat-cron.sh <<'EOF'
#!/bin/bash
AGENT_ID="сюда-id-агента"
curl -sf -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}' > /dev/null
EOF
chmod +x ~/heartbeat-cron.sh

# Каждые 5 минут
crontab - <<'EOF'
*/5 * * * * /home/openclaw/heartbeat-cron.sh
EOF
```

## 9. Готово

У тебя теперь:
- Paperclip запущен в `local_trusted` (без внешней БД)
- OpenClaw gateway с watchdog (переживает ребут)
- Bridge-агент, который отвечает через MiniMax M3 через wormsoft
- Доплата: 0₽. Всё входит в твою подписку OpenClaw.

Дальше:
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — почему именно так устроено
- **[TROUBLESHOOTING.ru.md](./TROUBLESHOOTING.ru.md)** — баги, которые мы словили, и фиксы
- **[scripts/smoke-test.sh](./scripts/smoke-test.sh)** — автотест, который проверяет, что мост жив

## FAQ на старте

**Q: Это легально — гонять GPT-5.2 через wormsoft, если модель на самом деле MiniMax M3?**
A: Это твоя подписка OpenClaw, ты вправе её использовать. MiniMax M3 — open-source LLM, лицензия Apache 2.0. Юридических проблем нет.

**Q: А качество не хуже, чем у настоящего GPT-5?**
A: Хуже, да. На уровне GPT-4o. Если тебе нужен именно GPT-5 — плати OpenAI. Если тебе нужен агент, который решает задачи — MiniMax справляется.

**Q: Можно я добавлю своего агента с другими инструкциями?**
A: Да. Создай нового агента через API, поменяй поле `instructions` в Paperclip. OpenClaw умеет держать несколько параллельных сессий.