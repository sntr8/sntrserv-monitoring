#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

THRESHOLD=85

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

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
            notify "⚠️ <b>${host_label}</b>: disk usage at ${usage}% (threshold ${THRESHOLD}%)"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ <b>${host_label}</b>: disk usage back down to ${usage}%"
            rm -f "$state_file"
        fi
    fi
}

check_host "Vampire" "df --output=pcent / | tail -1"
check_host "Corsair" "ssh corsair.sntrserv.net \"df --output=pcent / | tail -1\""
