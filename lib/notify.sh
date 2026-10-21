#!/bin/bash
# Shared Telegram notify helper. Source this after sourcing
# /home/sntr/.telegram_alert.env (needs TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID).

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" >/dev/null
}
