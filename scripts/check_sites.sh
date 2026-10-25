#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STATE_DIR="/home/sntr/scripts"
TIMEOUT=12

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh
source /home/sntr/git/sntrserv-monitoring/lib/sites.sh

# Up or down is a binary condition, so this keeps the boolean state-file
# pattern rather than the tiered one. A site is either serving what it should
# or it is not; there is no "slightly down".
for entry in "${SITES[@]}"; do
    domain="${entry%%|*}"
    expected="${entry##*|}"
    state_file="${STATE_DIR}/.site_down_${domain}"

    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "https://${domain}" 2>/dev/null || echo "000")

    if [ "$code" != "$expected" ]; then
        if [ ! -f "$state_file" ]; then
            if [ "$code" = "000" ]; then
                notify "🔴 <b>${domain}</b>: no response within ${TIMEOUT}s"
            else
                notify "🔴 <b>${domain}</b>: HTTP ${code}, expected ${expected}"
            fi
            echo "$code" > "$state_file"
        fi
    else
        if [ -f "$state_file" ]; then
            notify "✅ <b>${domain}</b>: back to HTTP ${code}"
            rm -f "$state_file"
        fi
    fi
done
