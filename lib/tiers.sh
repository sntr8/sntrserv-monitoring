#!/bin/bash
# Shared tiered-alert helper for metrics that get progressively worse.
#
# The boolean state-file pattern used by the other checks is right for a
# condition that is either true or false (container down, backup stale). It is
# wrong for a continuous value: once it has alerted, it stays silent no matter
# how much worse things get. This helper alerts once per severity tier crossed
# instead, so a disk that keeps filling keeps reporting.
#
# Source after lib/notify.sh.

TIER_STATE_DIR="${TIER_STATE_DIR:-/home/sntr/scripts}"

# tiered_alert METRIC HOST VALUE DIRECTION TIER_SPEC DETAIL RECOVERY
#
#   METRIC    short name, used in state filenames (disk, load, mem)
#   HOST      label for the message (Vampire, Corsair)
#   VALUE     current value; may be decimal
#   DIRECTION above = higher is worse (disk, load)
#             below = lower is worse  (memory available, days to cert expiry)
#   TIER_SPEC threshold:emoji:consecutive entries, ORDERED LEAST SEVERE FIRST.
#             `consecutive` is how many back-to-back breaches that tier needs
#             before it alerts, which dampens brief spikes on the mild tiers
#             without delaying the severe ones.
#   DETAIL    message body; `{tier}` is replaced with the threshold crossed
#   RECOVERY  message body for the back-to-normal alert
#
# Alerts once per tier, escalating only. Never repeats or de-escalates a tier,
# so a value wobbling just under a threshold stays quiet. Sends recovery and
# resets once the value clears every tier.
tiered_alert() {
    local metric="$1" host="$2" value="$3" direction="$4" spec="$5"
    local detail="$6" recovery="$7"

    local state_file="${TIER_STATE_DIR}/.${metric}_tier_${host}"
    local counter_file="${TIER_STATE_DIR}/.${metric}_counter_${host}"

    # Walk the tiers least-severe first; the last one breached is the worst.
    # Severity is the tier's position in the list, not its threshold, so
    # "below" metrics rank correctly without inverting any comparisons.
    local sev=0 threshold="" emoji="" needed=1
    local idx=0 entry t e c
    for entry in $spec; do
        idx=$((idx + 1))
        IFS=: read -r t e c <<<"$entry"
        if awk -v v="$value" -v t="$t" -v d="$direction" \
               'BEGIN{exit !(d=="above" ? v>=t : v<=t)}'; then
            sev="$idx"; threshold="$t"; emoji="$e"; needed="$c"
        fi
    done

    local last_sev=0
    [ -f "$state_file" ] && last_sev=$(cat "$state_file")

    if [ "$sev" -eq 0 ]; then
        rm -f "$counter_file"
        if [ "$last_sev" -gt 0 ]; then
            notify "✅ <b>${host}</b>: ${recovery}"
            rm -f "$state_file"
        fi
        return 0
    fi

    local count=0
    [ -f "$counter_file" ] && count=$(cat "$counter_file")
    count=$((count + 1))
    echo "$count" > "$counter_file"

    if [ "$sev" -gt "$last_sev" ] && [ "$count" -ge "$needed" ]; then
        notify "${emoji} <b>${host}</b>: ${detail//\{tier\}/$threshold}"
        echo "$sev" > "$state_file"
    fi
}
