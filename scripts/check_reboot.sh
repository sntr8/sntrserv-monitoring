#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env
source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

STATE_DIR="/home/sntr/scripts"

check_host() {
    local host="$1" ssh_prefix="$2"
    local state_file="${STATE_DIR}/.reboot_needed_${host}"

    local needed=0
    if [ -z "$ssh_prefix" ]; then
        needs-restarting -r >/dev/null 2>&1 || needed=1
    else
        eval "$ssh_prefix needs-restarting -r" >/dev/null 2>&1 || needed=1
    fi

    if [ "$needed" -eq 1 ]; then
        if [ ! -f "$state_file" ]; then
            notify "⚠️ <b>${host}</b>: reboot required to apply pending kernel/library updates"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ <b>${host}</b>: rebooted, no longer pending"
            rm -f "$state_file"
        fi
    fi
}

check_host "Vampire" ""
check_host "Corsair" "ssh corsair.sntrserv.net"
