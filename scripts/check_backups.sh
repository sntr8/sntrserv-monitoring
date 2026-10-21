#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

BUCKET="sntrserv-hetzner-205426720339-eu-north-1-an"
REGION="eu-north-1"
STALE_THRESHOLD_HOURS=36
STATE_DIR="/home/sntr/scripts"

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

check_prefix() {
    local prefix="$1"
    local state_file="${STATE_DIR}/.backup_alerted_${prefix}"

    local latest_date
    latest_date=$(aws s3 ls "s3://${BUCKET}/${prefix}/" --region "$REGION" 2>/dev/null \
        | awk '{print $2}' | tr -d '/' | sort | tail -1)

    local problem=0
    local reason=""

    if [ -z "$latest_date" ]; then
        problem=1
        reason="no backup folders found at all"
    else
        local latest_epoch now_epoch age_hours
        latest_epoch=$(date -d "$latest_date" +%s)
        now_epoch=$(date +%s)
        age_hours=$(( (now_epoch - latest_epoch) / 3600 ))

        if [ "$age_hours" -gt "$STALE_THRESHOLD_HOURS" ]; then
            problem=1
            reason="latest backup is from ${latest_date}, ${age_hours}h ago"
        else
            local zero_byte_files
            zero_byte_files=$(aws s3 ls "s3://${BUCKET}/${prefix}/${latest_date}/" --region "$REGION" --recursive 2>/dev/null \
                | awk '$3 == 0 {print $4}')
            if [ -n "$zero_byte_files" ]; then
                problem=1
                reason="zero-byte backup file(s) in ${latest_date}: ${zero_byte_files}"
            fi
        fi
    fi

    if [ "$problem" -eq 1 ]; then
        if [ ! -f "$state_file" ]; then
            notify "🔴 Backup (${prefix}): ${reason}"
            touch "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ Backup (${prefix}): back to normal, latest from ${latest_date}"
            rm -f "$state_file"
        fi
    fi
}

check_prefix "vampire"
check_prefix "corsair"
