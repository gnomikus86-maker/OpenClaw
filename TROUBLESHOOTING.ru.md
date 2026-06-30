# Troubleshooting

Каждая ошибка, что мы словили, что её вызвало, и как починить. Если у тебя что-то не работает — начни отсюда.

---

## OpenClaw gateway

### `gateway token mismatch (provide gateway auth token)`

**Что видишь** (в статусе агента Paperclip):
```json
{ "status": "error", "errorReason": "unauthorized: gateway token mismatch (provide gateway auth token)" }
```

**Причина**: `authToken` в конфиге Paperclip-агента не совпадает с `gateway.auth.token` в `~/.openclaw/openclaw.json`.

**Решение**:
```bash
# Узнай, что ждёт OpenClaw:
OC_TOKEN=$(python3 -c "import json; print(json.load(open('/home/openclaw/.openclaw/openclaw.json'))['gateway']['auth']['token'])")
echo "OpenClaw ждёт: $OC_TOKEN"

# Обнови агента в Paperclip:
curl -X PATCH http://127.0.0.1:3100/api/agents/$AGENT_ID \
  -H "Content-Type: application/json" \
  -d "{\"adapterConfig\": {\"authToken\": \"$OC_TOKEN\"}}"
```

Или наоборот — отредактируй `~/.openclaw/openclaw.json` и поставь туда токен из Paperclip. Первый способ чище.

---

### `missing scope: operator.write`

**Что видишь**:
```json
{ "errorReason": "missing scope: operator.write" }
```

**Причина**: в `adapterConfig` Paperclip стоит `disableDeviceAuth: true`. Gateway принимает коннект (токен совпал), но scopes не привязывает.

**Решение**:
```bash
curl -X PATCH http://127.0.0.1:3100/api/agents/$AGENT_ID \
  -H "Content-Type: application/json" \
  -d '{"adapterConfig": {"disableDeviceAuth": false}}'

# И триггерни heartbeat:
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}'
```

Не добавляй `scopes` в `adapterConfig` — gateway их игнорирует (см. [ARCHITECTURE.md](./ARCHITECTURE.md)).

---

### `connect ECONNREFUSED 127.0.0.1:18789`

**Что видишь**:
```json
{ "errorReason": "connect ECONNREFUSED 127.0.0.1:18789" }
```

**Причина**: OpenClaw gateway не слушает.

**Решение**:
```bash
systemctl --user status openclaw-gateway.service
# Если "inactive (dead)":
systemctl --user start openclaw-gateway.service

# Если не стартует:
sudo -n /usr/bin/journalctl -u openclaw-gateway.service -n 30 --no-pager
```

Если жалуется «another gateway instance is already listening» — убей orphan:
```bash
ps -ef | grep openclaw-gateway | grep -v grep
sudo -n /usr/bin/kill -9 <orphan-PID>
systemctl --user start openclaw-gateway.service
```

---

### Gateway час поработал и умер

**Причина**: user systemd умер при выходе пользователя, а `enable-linger` не выставлен.

**Решение** (один раз, навсегда):
```bash
loginctl enable-linger openclaw
```

Проверка:
```bash
loginctl show-user openclaw | grep Linger
# Должно быть: Linger=yes
```

---

### `Failed to connect to bus` на `systemctl --user status`

**Причина**: ты зашёл, но `pam_systemd` не стартанул user-сессию (бывает при `su` или неинтерактивных входах).

**Решение**:
```bash
loginctl list-sessions | grep openclaw
# Если пусто:
loginctl enable-linger openclaw
# Или перелогинься, или:
sudo loginctl activate-user openclaw
```

---

## Paperclip

### `sign-in/email 200 → get-session 401`

**Что видишь**: логинишься в Paperclip UI, редирект на dashboard, dashboard зовёт `/api/auth/get-session`, получает 401.

**Причина**: известный баг better-auth в режиме `authenticated`.

**Решение**: переключись на `local_trusted`. В `~/.paperclip/.env`:

```bash
PAPERCLIP_DEPLOYMENT_MODE=local_trusted
BIND=loopback
```

Перезапусти:
```bash
sudo systemctl restart paperclip.service
```

Получишь неявную сессию `local-board` — логин не нужен. Если нужна реальная авторизация, см. доку Paperclip по better-auth (заложи день на дебаг).

---

### Paperclip не стартует: `embedded postgres already exists`

**Что видишь**:
```
Embedded PostgreSQL cluster already exists; skipping init
```
потом зависает.

**Причина**: залипший лок-файл или битая embedded БД. Обычно после жёсткого kill.

**Решение**:
```bash
sudo systemctl stop paperclip.service
# БД не удалять! Только лок:
sudo rm /home/openclaw/paperclip/data/postmaster.pid 2>/dev/null
sudo systemctl start paperclip.service
```

Если не помогло — проверь место на диске (`df -h /`). Embedded postgres отказывается стартовать, если не может писать WAL.

---

### `heartbeat.enabled = true`, но heartbeat не срабатывает

**Причина**: известный баг Paperclip 2026.626.0. Авто-heartbeat медленный (лаг 5+ минут) и иногда не срабатывает, если нет on-demand триггера.

**Решение**: используй manual invoke в cron:
```bash
cat > ~/heartbeat-cron.sh <<EOF
#!/bin/bash
AGENT_ID="\$1"
[ -z "\$AGENT_ID" ] && { echo "Usage: \$0 <agent-id>"; exit 1; }
curl -sf -X POST http://127.0.0.1:3100/api/agents/\$AGENT_ID/heartbeat/invoke \
  -H "Content-Type: application/json" -d '{}' > /dev/null
EOF
chmod +x ~/heartbeat-cron.sh

# Каждые 5 минут
crontab - <<EOF
*/5 * * * * /home/openclaw/heartbeat-cron.sh $AGENT_ID
EOF
```

---

### Агент в `status: error` после починки причины

**Причина**: Paperclip кэширует error-статус до следующего heartbeat.

**Решение**:
```bash
# Триггерни heartbeat
curl -X POST http://127.0.0.1:3100/api/agents/$AGENT_ID/heartbeat/invoke

# Подожди 10-30 секунд, проверь:
curl -s http://127.0.0.1:3100/api/agents/$AGENT_ID | python3 -m json.tool | grep -E 'status|errorReason'
```

---

## Wormsoft / модель

### `invalid API key` от wormsoft

**Причина**: твой wormsoft-ключ истёк или отозван.

**Решение**:
1. Зайди в личный кабинет OpenClaw
2. Найди раздел wormsoft API
3. Регенерируй ключ
4. Обнови Paperclip `.env`:
   ```bash
   sed -i "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$NEW_KEY/" ~/paperclip/.env
   sudo systemctl restart paperclip.service
   ```

### Модель отдаёт 429 (rate limit)

**Причина**: превысил бесплатную квоту wormsoft.

**Решение**:
- Подожди час
- Или апгрейдни план в личном кабинете OpenClaw
- Или переключись на другой провайдер (см. ARCHITECTURE.md → Extending)

### Модель несёт чушь на русском

**Причина**: MiniMax M3 нормально говорит по-английски, средне — по-русски. Это китайская модель с английской выборкой.

**Решение**: пока не спрашивай её про русский. Или переключись на другую модель через конфиг Paperclip.

---

## GitHub-публикация

### `Permission denied` при push в GitHub

**Причина**: неправильные scope у токена. Fine-grained PAT нужны `Contents: Read+Write` + `Metadata: Read`. Classic PAT нужен `repo`.

**Решение**: регенерируй токен на https://github.com/settings/tokens с правильными scope.

### `Repository not found` при правильном URL

**Причина**: fine-grained PAT scoped только на конкретные репо, и ты не добавил нужное.

**Решение**: отредактируй PAT → Repository access → добавь репо (или выбери All repositories).

---

## Когда совсем непонятно, что делать

1. Смотри логи нужного сервиса:
   ```bash
   journalctl -u paperclip.service -n 100 --no-pager
   journalctl --user -u openclaw-gateway.service -n 100 --no-pager
   ```
2. Проверь OpenClaw gateway напрямую: `openclaw gateway call health`
3. Проверь Paperclip API: `curl http://127.0.0.1:3100/api/health`
4. Проверь wormsoft напрямую:
   ```bash
   curl -s https://ai.wormsoft.ru/api/gpt/v1/chat/completions \
     -H "Authorization: Bearer $OPENAI_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model":"openai/gpt-5.2","messages":[{"role":"user","content":"Reply with: hello"}]}'
   ```
5. Если ничего не помогло — открой issue на GitHub с логами всех трёх.

---

## Реальные грабли, на которые мы наступили (и которых нет в чужой доке)

- **OpenClaw watchdog умирает без `enable-linger`.** Все гайды молчат. Мы ловили в 3 ночи.
- **Paperclip `codex_local` заточен под ChatGPT-подписку.** Прямой API-ключ игнорируется, auth.json переписывается. Используй `openclaw_gateway` — он работает.
- **`scopes` в `adapterConfig` — иллюзия.** Gateway берёт scopes из device-pair-store, не из конфига. Добавить `operator.write` в конфиг — не поможет.
- **`disableDeviceAuth: true` ломает scope-binding.** С ним — нет scopes. Без него — есть.
- **Heartbeat-инвойк по расписанию — медленный.** В Paperclip 2026.626.0 лагает 5+ минут. Оборачивай в cron.
- **JWT для Paperclip пропадает после ребута.** Лог: `Agent JWT missing (run pnpm paperclipai onboard)`. В `local_trusted` это не страшно (implicit session), но пугает.