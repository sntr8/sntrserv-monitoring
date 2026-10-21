#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

THRESHOLD_DAYS=14
STATE_DIR="/home/sntr/scripts"

HOSTS=(
    sleeves.sntrserv.net
    kuvat.lehtone.nl
    workform.erikoispumppaus.fi
    patchwork.sntrserv.net
    techdemo.saaresti.eu
    kivikarinkuja.sntrserv.net
    tesla.sntrserv.net
)

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

for host in "${HOSTS[@]}"; do
    state_file="${STATE_DIR}/.cert_alerted_${host}"

    end_date=$(echo | timeout 10 openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [ -z "$end_date" ]; then
        continue
    fi

    expiry_epoch=$(date -d "$end_date" +%s)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -lt "$THRESHOLD_DAYS" ]; then
        if [ ! -f "$state_file" ]; then
            notify "⚠️ <b>${host}</b>: TLS cert expires in ${days_left} days (${end_date})"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ <b>${host}</b>: TLS cert renewed, ${days_left} days remaining"
            rm -f "$state_file"
        fi
    fi
done
