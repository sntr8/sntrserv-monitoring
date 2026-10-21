#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

URL="https://workform.erikoispumppaus.fi"
STATE_FILE="/home/sntr/scripts/.erikoispumppaus_down"

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL" || echo "000")

if [ "$CODE" != "200" ]; then
    if [ ! -f "$STATE_FILE" ]; then
        notify "🔴 erikoispumppaus.fi unreachable (HTTP $CODE) at $(date '+%Y-%m-%d %H:%M')"
        touch "$STATE_FILE"
    fi
else
    if [ -f "$STATE_FILE" ]; then
        notify "✅ erikoispumppaus.fi back up at $(date '+%Y-%m-%d %H:%M')"
        rm -f "$STATE_FILE"
    fi
fi
