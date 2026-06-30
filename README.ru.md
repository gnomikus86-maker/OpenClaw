# Paperclip × OpenClaw Bridge

> Поднимаем **Paperclip**-агента, который думает через **MiniMax M3** (маркетинговое название «GPT-5.2») — на твоей подписке OpenClaw. **0₽ дополнительно.**

[![status](https://img.shields.io/badge/status-работает-brightgreen)]()
[![paperclip](https://img.shields.io/badge/paperclip-2026.626-purple)]()
[![openclaw](https://img.shields.io/badge/openclaw-2026.4.1-orange)]()
[![license](https://img.shields.io/badge/license-MIT-blue)]()
[![cost](https://img.shields.io/badge/доплата-0%20₽%2Fмес-success)]()

## Что это?

У тебя есть:

- **OpenClaw** — AI-ассистент и WebSocket-шлюз (подписка 2500₽/мес, в неё входит прокси `wormsoft`)
- **Paperclip** — опенсорсный оркестратор AI-агентов (self-hosted)
- **wormsoft** — OpenAI-совместимый прокси, через который идёт **MiniMax M3** (китайская LLM, маркетингово продаётся под именами GPT-5.x, по качеству — крепкий GPT-4o)

Ты хочешь: Paperclip-агента, который реально работает, гоняет MiniMax M3 под капотом, и **не стоит тебе ни копейки сверх подписки OpenClaw**.

Этот репо — мост, который их соединяет. На то, чтобы его собрать, у нас ушло **14 часов дебага и одна ночная перезагрузка сервера**. Теперь всё задокументировано.

## Зачем?

| Альтернатива | Стоимость | Подвох |
|---|---|---|
| OpenAI напрямую | от $20/мес | У тебя нет нерусской карты. |
| proxyapi.ru | 1500₽/мес | Только российская карта, ещё один вендор. |
| **OpenClaw + wormsoft + MiniMax** | **0₽ сверху** | Китайская модель. Качество на уровне GPT-4o, не настоящий GPT-5. |

Если «крепкий GPT-4o» для твоих задач агента достаточно — экономишь 1500₽/мес и не зависишь от вендора.

## TL;DR

```bash
# 1. Установи Paperclip (см. INSTALL.ru.md)
npm install -g @paperclipai/server
# ... настрой local_trusted + bind loopback

# 2. Положи wormsoft-ключ в Paperclip .env
echo 'OPENAI_API_KEY=сюда-свой-ключ' >> ~/.paperclip/.env
echo 'PAPERCLIP_CODEX_PROVIDERS={"providers":{"wormsoft":{"base_url":"https://ai.wormsoft.ru/api/gpt/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}}}' >> ~/.paperclip/.env

# 3. Создай bridge-агента через API
curl -X POST http://localhost:3100/api/companies/<COMPANY_ID>/agents \
  -H "Content-Type: application/json" \
  -d @examples/openclaw-bridge-agent.json

# 4. Триггерни heartbeat
curl -X POST http://localhost:3100/api/agents/<AGENT_ID>/heartbeat/invoke

# 5. Создай тестовый issue
curl -X POST http://localhost:3100/api/companies/<COMPANY_ID>/issues \
  -H "Content-Type: application/json" \
  -d '{"title":"Пинг","description":"Ответь, какой сегодня день недели.","status":"todo","assigneeAgentId":"<AGENT_ID>"}'

# 6. Подожди ~60 сек. Агент ответит.
```

Полная пошаговая инструкция — **[INSTALL.ru.md](./INSTALL.ru.md)**.

## Что в коробке

- **[INSTALL.ru.md](./INSTALL.ru.md)** — установка с нуля: Paperclip + OpenClaw + интеграция
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** (English) — как мост работает, почему именно device auth, почему scopes в конфиге бесполезны
- **[TROUBLESHOOTING.ru.md](./TROUBLESHOOTING.ru.md)** — каждую ошибку, что мы встретили, и как починить
- **[examples/](./examples/)** — копируй-вставляй: JSON-конфиги и env-шаблоны
- **[scripts/](./scripts/)** — автоматизация: heartbeat cron, health check, e2e smoke test

## Как это работает (на человеческом)

Ты создаёшь issue в Paperclip. Агент просыпается. Через WebSocket стучится в OpenClaw. OpenClaw пересылает запрос в wormsoft (это в твоей подписке). wormsoft зовёт MiniMax M3. Ответ летит обратно. Агент публикует его как комментарий в issue и закрывает его в `done`.

Реальный лог с реального запуска:

> «Сейчас вторник (Tue 2026-06-30, 07:02 UTC), а 7*6 = 42. Handshake работает end-to-end: Paperclip → /api/issues/{id} → OpenClaw-Bridge (ws://127.0.0.1:18789, scopes: operator.admin/write/read) → wormsoft → MiniMax-M3.»

## Что НЕ работает (пока)

- **CEO-агент через `codex_local`** — заточен под ChatGPT-подписку, не скормишь наш ключ. Используй `openclaw_gateway` (это и есть наш мост).
- **Авто-heartbeat по расписанию** — работает, но медленно. Оберни в cron и не парься (скрипт в `scripts/heartbeat-cron.sh`).
- **Multi-tenant Paperclip** — `local_trusted` это single-tenant. Для мульти-тенант переходи на `authenticated`, но там другие баги (см. TROUBLESHOOTING).

## Протестировано на

- Paperclip `2026.626.0`
- OpenClaw `2026.4.1`
- Ubuntu 24.04, Node 22
- OpenClaw Gateway как `systemd --user` сервис с `enable-linger`

## Лицензия

MIT. Используй, форкай, делай сервис поверх, продавай — без ограничений.

## Деньги? 💰

Этот проект экономит 1500₽/мес каждому, кто его поставит. Если ты фрилансер или самозанятый:

- **Tier 1 (бесплатно)**: этот репо. Сам поставишь за час.
- **Tier 2 (платно)**: тебе поставят под ключ. Разумная цена: 5-10к₽ разово.
- **Tier 3 (managed)**: хостинг Paperclip + мост за ежемесячную плату.

Контакт: открой issue или см. USER.md в основном workspace.

---

*«Зачем платить за OpenAI, если у тебя уже есть подписка с нормальной моделью?»*