#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh
source /home/sntr/git/sntrserv-monitoring/lib/tiers.sh

# threshold:emoji:consecutive-breaches-needed, least severe first.
# Disk moves slowly and never spikes, so every tier alerts on the first breach.
DISK_TIERS="85:⚠️:1 90:⚠️:1 95:🔴:1 98:🔴:1"

check_host() {
    local host_label="$1"
    local usage_cmd="$2"

    local usage
    usage=$(eval "$usage_cmd" | tr -dc '0-9')

    if [ -z "$usage" ]; then
        return 0
    fi

    tiered_alert disk "$host_label" "$usage" above "$DISK_TIERS" \
        "disk usage at ${usage}% (crossed {tier}%)" \
        "disk usage back down to ${usage}%"
}

check_host "Vampire" "df --output=pcent / | tail -1"
check_host "Corsair" "ssh corsair.sntrserv.net \"df --output=pcent / | tail -1\""
