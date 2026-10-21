#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

THRESHOLD=85

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

check_host() {
    local host_label="$1"
    local usage_cmd="$2"
    local state_file="/home/sntr/scripts/.disk_warning_${host_label}"

    local usage
    usage=$(eval "$usage_cmd" | tr -dc '0-9')

    if [ -z "$usage" ]; then
        return
    fi

    if [ "$usage" -ge "$THRESHOLD" ]; then
        if [ ! -f "$state_file" ]; then
            notify "⚠️ ${host_label}: disk usage at ${usage}% (threshold ${THRESHOLD}%)"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ ${host_label}: disk usage back down to ${usage}%"
            rm -f "$state_file"
        fi
    fi
}

check_host "vampire" "df --output=pcent / | tail -1"
check_host "corsair" "ssh corsair.sntrserv.net \"df --output=pcent / | tail -1\""
