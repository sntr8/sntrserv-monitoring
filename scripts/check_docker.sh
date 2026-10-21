#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STATE_DIR="/home/sntr/scripts"

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

docker ps -a --format '{{.Names}}|{{.Status}}' | while IFS='|' read -r name status; do
    state_file="${STATE_DIR}/.docker_alerted_${name}"
    problem=0

    if [[ "$status" != Up* ]] || [[ "$status" == *"(unhealthy)"* ]]; then
        problem=1
    fi

    if [ "$problem" -eq 1 ]; then
        if [ ! -f "$state_file" ]; then
            notify "🔴 Docker container '${name}' is unhealthy: ${status}"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ Docker container '${name}' recovered: ${status}"
            rm -f "$state_file"
        fi
    fi
done
