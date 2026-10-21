#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STATE_DIR="/home/sntr/scripts"

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

docker ps -a --format '{{.Names}}|{{.Status}}' | while IFS='|' read -r name status; do
    state_file="${STATE_DIR}/.docker_alerted_${name}"
    problem=0

    if [[ "$status" != Up* ]] || [[ "$status" == *"(unhealthy)"* ]]; then
        problem=1
    fi

    if [ "$problem" -eq 1 ]; then
        if [ ! -f "$state_file" ]; then
            notify "🔴 <b>${name}</b>: unhealthy (${status})"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ <b>${name}</b>: recovered (${status})"
            rm -f "$state_file"
        fi
    fi
done
