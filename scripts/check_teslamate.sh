#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STALE_THRESHOLD_SECONDS=86400  # 24h
STATE_FILE="/home/sntr/scripts/.teslamate_stale"

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

AGE=$(docker exec teslamate-database-1 psql -U teslamate -d teslamate -t -c \
    "SELECT COALESCE(extract(epoch from (now() - max(date))), 999999)::bigint FROM positions;" \
    | tr -d ' ')

if [ -z "$AGE" ]; then
    exit 0
fi

if [ "$AGE" -gt "$STALE_THRESHOLD_SECONDS" ]; then
    if [ ! -f "$STATE_FILE" ]; then
        HOURS=$((AGE / 3600))
        notify "🔴 TeslaMate: no car position update in ${HOURS}h — car may have stopped reporting"
        touch "$STATE_FILE"
    fi
else
    if [ -f "$STATE_FILE" ]; then
        notify "✅ TeslaMate: car is reporting again"
        rm -f "$STATE_FILE"
    fi
fi
