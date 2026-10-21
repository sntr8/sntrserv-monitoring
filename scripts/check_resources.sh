#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

LOAD_RATIO_THRESHOLD=1.5    # 5-min load average / core count
MEM_AVAIL_THRESHOLD=15      # alert if available memory drops below this %
REQUIRED_CONSECUTIVE=3      # must breach this many checks in a row before alerting

STATE_DIR="/home/sntr/scripts"

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

track_and_alert() {
    local metric="$1" host="$2" breached="$3" detail="$4"
    local counter_file="${STATE_DIR}/.${metric}_counter_${host}"
    local alert_file="${STATE_DIR}/.${metric}_alerted_${host}"

    if [ "$breached" = "1" ]; then
        local count=0
        [ -f "$counter_file" ] && count=$(cat "$counter_file")
        count=$((count + 1))
        echo "$count" > "$counter_file"
        if [ "$count" -ge "$REQUIRED_CONSECUTIVE" ] && [ ! -f "$alert_file" ]; then
            notify "⚠️ <b>${host}</b>: ${detail}"
            touch "$alert_file"
        fi
    else
        rm -f "$counter_file"
        if [ -f "$alert_file" ]; then
            notify "✅ <b>${host}</b>: ${metric} back to normal"
            rm -f "$alert_file"
        fi
    fi
}

check_host() {
    local host="$1" ssh_prefix="$2"
    local nproc_val load5 total avail

    if [ -z "$ssh_prefix" ]; then
        nproc_val=$(nproc)
        load5=$(awk '{print $2}' /proc/loadavg)
        read -r total avail < <(free -m | awk '/^Mem:/{print $2, $7}')
    else
        nproc_val=$(eval "$ssh_prefix nproc")
        load5=$(eval "$ssh_prefix cat /proc/loadavg" | awk '{print $2}')
        read -r total avail < <(eval "$ssh_prefix free -m" | awk '/^Mem:/{print $2, $7}')
    fi

    local load_ratio load_breached=0
    load_ratio=$(awk -v l="$load5" -v n="$nproc_val" 'BEGIN{printf "%.2f", l/n}')
    awk -v r="$load_ratio" -v t="$LOAD_RATIO_THRESHOLD" 'BEGIN{exit !(r>t)}' && load_breached=1

    local mem_avail_pct mem_breached=0
    mem_avail_pct=$(awk -v a="$avail" -v t="$total" 'BEGIN{printf "%.0f", (a*100)/t}')
    [ "$mem_avail_pct" -lt "$MEM_AVAIL_THRESHOLD" ] && mem_breached=1

    track_and_alert "load" "$host" "$load_breached" "5-min load ratio ${load_ratio}x (${nproc_val} cores) for ${REQUIRED_CONSECUTIVE}+ checks"
    track_and_alert "mem" "$host" "$mem_breached" "only ${mem_avail_pct}% memory available for ${REQUIRED_CONSECUTIVE}+ checks"
}

check_host "Vampire" ""
check_host "Corsair" "ssh corsair.sntrserv.net"
