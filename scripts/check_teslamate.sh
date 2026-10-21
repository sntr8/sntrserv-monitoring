#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STALE_THRESHOLD_SECONDS=86400  # 24h
STATE_FILE="/home/sntr/scripts/.teslamate_stale"

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

AGE=$(docker exec teslamate-database-1 psql -U teslamate -d teslamate -t -c \
    "SELECT COALESCE(extract(epoch from (now() - max(date))), 999999)::bigint FROM positions;" \
    | tr -d ' ')

if [ -z "$AGE" ]; then
    exit 0
fi

if [ "$AGE" -gt "$STALE_THRESHOLD_SECONDS" ]; then
    if [ ! -f "$STATE_FILE" ]; then
        HOURS=$((AGE / 3600))
        notify "🔴 <b>TeslaMate</b>: no car position update in ${HOURS}h — car may have stopped reporting"
        touch "$STATE_FILE"
    fi
else
    if [ -f "$STATE_FILE" ]; then
        notify "✅ <b>TeslaMate</b>: car is reporting again"
        rm -f "$STATE_FILE"
    fi
fi
