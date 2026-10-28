#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

STATE_DIR="/home/sntr/scripts"
TIMEOUT=12
# Consecutive failed runs before alerting. Up/down is binary, but response time
# is not: a site whose page render depends on third-party upstreams (lunchy)
# can miss the timeout budget once without being down. One run is 5 min, so
# this delays a real outage alert by 5 min and silences every single-run blip.
FAIL_THRESHOLD=2

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh
source /home/sntr/git/sntrserv-monitoring/lib/sites.sh

for entry in "${SITES[@]}"; do
    domain="${entry%%|*}"
    expected="${entry##*|}"
    state_file="${STATE_DIR}/.site_down_${domain}"
    count_file="${STATE_DIR}/.site_fail_count_${domain}"

    # curl's -w already prints 000 when the request never completed, so this
    # must not append a fallback of its own: doing that produced "000000",
    # which then failed the "is it 000" test below and reported a timeout as
    # an HTTP status. Let the exit code pass and treat empty output as 000.
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "https://${domain}" 2>/dev/null) || true
    [ -n "$code" ] || code="000"

    if [ "$code" != "$expected" ]; then
        fails=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
        echo "$fails" > "$count_file"

        if [ "$fails" -ge "$FAIL_THRESHOLD" ] && [ ! -f "$state_file" ]; then
            if [ "$code" = "000" ]; then
                notify "🔴 <b>${domain}</b>: no response within ${TIMEOUT}s"
            else
                notify "🔴 <b>${domain}</b>: HTTP ${code}, expected ${expected}"
            fi
            echo "$code" > "$state_file"
        fi
    else
        rm -f "$count_file"
        if [ -f "$state_file" ]; then
            notify "✅ <b>${domain}</b>: back to HTTP ${code}"
            rm -f "$state_file"
        fi
    fi
done
