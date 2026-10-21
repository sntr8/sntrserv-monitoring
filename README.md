# sntrserv monitoring

Lightweight monitoring for Vampire and Corsair. No AI, no cloud monitoring stack,
just cron + curl + Telegram.

## Components

- **`scripts/heartbeat-ping.sh`** — run every 5 min via cron on each host. Pings
  that host's healthchecks.io check. If a host misses two check-ins in a row,
  healthchecks.io fires its "down" webhook, which posts straight to our Telegram
  bot (see below) instead of using healthchecks.io's own bot.
- **`scripts/check_php_patch.sh`** — runs every 15 min on Vampire. Checks Corsair
  for the PHP 8.3.36 security fix (CVE-2026-109618 / CVE-2026-109619) via
  `dnf check-update` over SSH, and Telegram-notifies once when it becomes
  available. Temporary — remove once Corsair is patched and this isn't a live
  concern anymore.

## Secrets (never committed)

Each host needs its own `/home/sntr/.monitoring.env` (its healthchecks.io ping
URL) and, where Telegram notifications are sent from, `/home/sntr/.telegram_alert.env`
(bot token + chat ID). See `.env.example` for the shape. Both files are `chmod 600`.

## healthchecks.io setup

Two checks: `vampire-heartbeat`, `corsair-heartbeat`. Period 5 min, grace 10 min.
Notifications go through the **Webhook** integration (not the built-in Telegram
integration, which is locked to healthchecks.io's own bot) pointed at our bot:

- Method: POST
- URL: `https://api.telegram.org/bot<TOKEN>/sendMessage`
- Header: `Content-Type: application/x-www-form-urlencoded`
- Body (down): `chat_id=<CHAT_ID>&text=\U0001f534 $NAME is DOWN since $NOW`
- Body (up): `chat_id=<CHAT_ID>&text=✅ $NAME recovered at $NOW`

## Cron entries

Vampire:
```
*/5  * * * * /home/sntr/sntrserv-monitoring/scripts/heartbeat-ping.sh
*/15 * * * * /home/sntr/sntrserv-monitoring/scripts/check_php_patch.sh
```

Corsair:
```
*/5  * * * * /home/sntr/sntrserv-monitoring/scripts/heartbeat-ping.sh
```
