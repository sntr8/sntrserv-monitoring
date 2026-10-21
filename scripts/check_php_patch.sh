#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STATE_FILE="/home/sntr/scripts/.php_patch_notified"

set +e
ssh corsair.sntrserv.net "dnf check-update php php-cli php-fpm php-common" >/tmp/php_check_update.out 2>&1
STATUS=$?
set -e

notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" >/dev/null
}

if [ "$STATUS" -eq 100 ]; then
    if [ ! -f "$STATE_FILE" ]; then
        notify "PHP update available on Corsair (CVE-2026-109618/109619 fix likely landed). Run: sudo dnf update -y php php-cli php-common php-fpm && sudo systemctl restart httpd php-fpm"
        touch "$STATE_FILE"
    fi
elif [ "$STATUS" -eq 0 ]; then
    rm -f "$STATE_FILE"
fi
