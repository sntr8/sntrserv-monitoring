#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

URL="https://workform.erikoispumppaus.fi"
STATE_FILE="/home/sntr/scripts/.erikoispumppaus_down"

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL" || echo "000")

if [ "$CODE" != "200" ]; then
    if [ ! -f "$STATE_FILE" ]; then
        notify "🔴 <b>erikoispumppaus.fi</b>: unreachable (HTTP $CODE) at $(date '+%Y-%m-%d %H:%M')"
        touch "$STATE_FILE"
    fi
else
    if [ -f "$STATE_FILE" ]; then
        notify "✅ <b>erikoispumppaus.fi</b>: back up at $(date '+%Y-%m-%d %H:%M')"
        rm -f "$STATE_FILE"
    fi
fi
