#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh
source /home/sntr/git/sntrserv-monitoring/lib/tiers.sh
source /home/sntr/git/sntrserv-monitoring/lib/sites.sh

# threshold_days:emoji:consecutive, least severe first. Days remaining is a
# continuous value that only gets worse, so it uses the tiered helper: 14 days
# is "certbot has had a chance and should have renewed by now", 3 days is "this
# is about to break in public".
CERT_TIERS="14:⚠️:1 3:🔴:1"

while read -r host; do
    end_date=$(echo | timeout 10 openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    # Unreachable host is check_sites.sh's job to report, not this script's.
    if [ -z "$end_date" ]; then
        continue
    fi

    expiry_epoch=$(date -d "$end_date" +%s)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    tiered_alert "cert_${host}" "$host" "$days_left" below "$CERT_TIERS" \
        "TLS cert expires in ${days_left} days (${end_date})" \
        "TLS cert renewed, ${days_left} days remaining"
done < <(site_domains)
