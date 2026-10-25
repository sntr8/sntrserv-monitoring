#!/bin/bash
set -euo pipefail

source /home/sntr/.telegram_alert.env

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh
source /home/sntr/git/sntrserv-monitoring/lib/tiers.sh

# threshold:emoji:consecutive-breaches-needed, least severe first.
#
# The mild tiers keep the old 3-consecutive-breach dampener, since a 5-min load
# average crossing 1.5x for one check is usually a build or a backup, not a
# problem. The severe tiers drop to 1: a host with 5% memory left may be dead
# before three checks have run, so waiting 15 minutes to say so is useless.
LOAD_TIERS="1.5:⚠️:3 3:🔴:1 5:🔴:1"     # 5-min load average / core count
MEM_TIERS="15:⚠️:3 10:⚠️:3 5:🔴:1"      # % memory available, lower is worse

# % of swap in use. On its own this is a soft signal: Linux will happily leave
# idle pages in swap with no ill effect, so a steady 40% is not a problem. It
# earns its place as the EARLIER warning than MemAvailable, which only drops
# once swap is already exhausted. Hence generous mild tiers and a dampener.
SWAP_TIERS="60:⚠️:3 80:⚠️:3 95:🔴:1"

check_host() {
    local host="$1" ssh_prefix="$2"
    local nproc_val load5 total avail

    if [ -z "$ssh_prefix" ]; then
        nproc_val=$(nproc)
        load5=$(awk '{print $2}' /proc/loadavg)
        read -r total avail < <(free -m | awk '/^Mem:/{print $2, $7}')
        read -r swap_total swap_used < <(free -m | awk '/^Swap:/{print $2, $3}')
    else
        nproc_val=$(eval "$ssh_prefix nproc")
        load5=$(eval "$ssh_prefix cat /proc/loadavg" | awk '{print $2}')
        read -r total avail < <(eval "$ssh_prefix free -m" | awk '/^Mem:/{print $2, $7}')
        read -r swap_total swap_used < <(eval "$ssh_prefix free -m" | awk '/^Swap:/{print $2, $3}')
    fi

    local load_ratio mem_avail_pct
    load_ratio=$(awk -v l="$load5" -v n="$nproc_val" 'BEGIN{printf "%.2f", l/n}')
    mem_avail_pct=$(awk -v a="$avail" -v t="$total" 'BEGIN{printf "%.0f", (a*100)/t}')

    # A host with swap disabled reports total 0; skip rather than divide by it.
    local swap_used_pct=""
    if [ "${swap_total:-0}" -gt 0 ]; then
        swap_used_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.0f", (u*100)/t}')
    fi

    tiered_alert load "$host" "$load_ratio" above "$LOAD_TIERS" \
        "5-min load ratio ${load_ratio}x on ${nproc_val} cores (crossed {tier}x)" \
        "load back to normal (${load_ratio}x)"

    tiered_alert mem "$host" "$mem_avail_pct" below "$MEM_TIERS" \
        "only ${mem_avail_pct}% memory available (crossed {tier}%)" \
        "memory back to normal (${mem_avail_pct}% available)"

    if [ -n "$swap_used_pct" ]; then
        tiered_alert swap "$host" "$swap_used_pct" above "$SWAP_TIERS" \
            "swap ${swap_used_pct}% used, ${swap_used}MB of ${swap_total}MB (crossed {tier}%)" \
            "swap back to normal (${swap_used_pct}% used)"
    fi
}

check_host "Vampire" ""
check_host "Corsair" "ssh corsair.sntrserv.net"
