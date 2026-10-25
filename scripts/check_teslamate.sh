#!/bin/bash
set -euo pipefail

# Is TeslaMate's connection to Tesla working?
#
# This deliberately does NOT alert on the car being idle. The previous version
# alerted when the `positions` table had no new row for 24h, which is wrong in
# both directions:
#
#   - False positive: TeslaMate only writes positions while the car is awake.
#     A car parked for a day or a week produces no rows at all, so every normal
#     idle period raised a "car may have stopped reporting" alert.
#   - False negative: during the 2026-06-22 outage (vehicle_data -> 403) the
#     streaming ingest kept writing positions the whole time. Only the REST
#     path, and therefore the `drives` rollup, was broken. A freshness check on
#     `positions` would have stayed silent through the one incident it existed
#     to catch.
#
# So the signals here are about the connection itself, not about the car moving:
# TeslaMate's own health flag, the 403 signature in its log, and proof that it
# is still refreshing its Tesla token. Position freshness is only consulted
# while the car reports `driving`, where a gap is unambiguous.
#
# Why this matters more than a dashboard being stale: TeslaMate is the e-logbook
# for kilometrikorvaus filing, so an unrecorded trip is lost data.

source /home/sntr/.telegram_alert.env
source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

STATE_DIR="/home/sntr/scripts"
DB_CONTAINER="teslamate-database-1"
APP_CONTAINER="teslamate-teslamate-1"
MQTT_CONTAINER="teslamate-mosquitto-1"

# Tesla access tokens last 8h and TeslaMate refreshes at 6h, so anything over
# the refresh interval but under token expiry works as a liveness window.
TOKEN_WINDOW_HOURS=8
# The 403 signature. A couple of lines can be a blip, a broken token handler
# repeats, and plain timeouts from Tesla are normal and must not match.
API_ERROR_WINDOW_HOURS=2
API_ERROR_MIN=3
# A car in `driving` writes positions every few seconds.
DRIVING_STALE_SECONDS=900
# `state` is a retained topic and arrives instantly, but `healthy` is published
# live with no retain flag, so the subscribe has to stay open long enough to
# catch one. Measured 2026-10-25 over 10 min with the car offline: 20 intervals,
# all 30-31s. 40 leaves ~9s of margin and is why this check takes ~41s per run.
MQTT_WAIT_SECONDS=40

# flag_alert KEY BAD ALERT RECOVERY [NEEDED]
#
# Boolean state-file pattern, same as check_docker.sh and check_sites.sh: alert
# once on the way in, once on the way out. Correct here because every condition
# below is binary, not a value that can keep getting worse, so lib/tiers.sh
# does not apply.
#
# NEEDED is how many back-to-back runs must see the fault before it alerts, the
# same dampener check_resources.sh uses. Default 1, for conditions that already
# contain their own dampener (a count over a window, or a multi-hour window).
flag_alert() {
    local key="$1" bad="$2" alert="$3" recovery="$4" needed="${5:-1}"
    local state_file="${STATE_DIR}/.teslamate_${key}"
    local counter_file="${STATE_DIR}/.teslamate_${key}_count"

    if [ "$bad" -eq 0 ]; then
        rm -f "$counter_file"
        if [ -f "$state_file" ]; then
            notify "$recovery"
            rm -f "$state_file"
        fi
        return 0
    fi

    local count=0
    [ -f "$counter_file" ] && count=$(cat "$counter_file")
    count=$((count + 1))
    echo "$count" > "$counter_file"

    if [ "$count" -ge "$needed" ] && [ ! -f "$state_file" ]; then
        notify "$alert"
        touch "$state_file"
    fi
}

psql_value() {
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A -c "$1" | tr -d ' '
}

# --- Token refresh: proves the container is alive and Tesla auth still works --
#
# TeslaMate logs almost nothing while the car is offline, so the 6-hourly token
# refresh is the only periodic proof of life. A container that started inside
# the window has not had time to log one yet, which is not a fault.
started_epoch=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$APP_CONTAINER")" +%s)
uptime_seconds=$(( $(date +%s) - started_epoch ))
refreshes=$(docker logs --since "${TOKEN_WINDOW_HOURS}h" "$APP_CONTAINER" 2>&1 \
    | grep -cE 'Scheduling token refresh|Refreshing access token' || true)

token_bad=0
if [ "$refreshes" -eq 0 ] && [ "$uptime_seconds" -gt $((TOKEN_WINDOW_HOURS * 3600)) ]; then
    token_bad=1
fi
flag_alert token "$token_bad" \
    "🔴 <b>TeslaMate</b>: no Tesla token refresh in ${TOKEN_WINDOW_HOURS}h, auth or the logger is stuck" \
    "✅ <b>TeslaMate</b>: Tesla token refresh is running again"

# --- The 2026-06-22 signature: forbidden/unauthorized on the Tesla API --------
# Matched against outbound Tesla calls only. TeslaMate also logs the requests
# it serves ("Sent 404 in 653us"), and a bare word match would count those.
api_errors=$(docker logs --since "${API_ERROR_WINDOW_HOURS}h" "$APP_CONTAINER" 2>&1 \
    | grep -iE -- 'tesla(motors)?\.com|owner-api' \
    | grep -ciE -- '-> 40[13]|forbidden|unauthorized' || true)

api_bad=0
if [ "$api_errors" -ge "$API_ERROR_MIN" ]; then
    api_bad=1
fi
flag_alert api_forbidden "$api_bad" \
    "🔴 <b>TeslaMate</b>: ${api_errors} forbidden/unauthorized Tesla API responses in ${API_ERROR_WINDOW_HOURS}h, drives are probably not being recorded" \
    "✅ <b>TeslaMate</b>: Tesla API responses are clean again"

# --- Per car: TeslaMate's own health flag, and gaps while actually driving ----
# A database outage is check_docker.sh's problem, so do not abort the check on it.
for car in $(psql_value "SELECT id FROM cars ORDER BY id;" || true); do
    # Reads MQTT rather than the database, because this asks whether TeslaMate
    # is getting data from Tesla, which is true or false regardless of whether
    # the car has moved. -W exits 27 by design once the wait is up.
    topics=$(docker exec "$MQTT_CONTAINER" mosquitto_sub -h localhost -v \
        -W "$MQTT_WAIT_SECONDS" \
        -t "teslamate/cars/${car}/healthy" \
        -t "teslamate/cars/${car}/state" 2>/dev/null || true)

    # The window is wider than the 30s publish interval, so a topic can show up
    # more than once. Take the newest value, not every value, or the comparison
    # below is against a multi-line string and always looks wrong.
    mqtt_last() {
        awk -v t="teslamate/cars/${car}/$1" '$1==t{v=$2} END{print v}' <<<"$topics"
    }
    healthy=$(mqtt_last healthy)
    state=$(mqtt_last state)

    # An empty flag means Mosquitto is unreachable or TeslaMate is not
    # publishing at all, neither of which is a Tesla connection fault, and
    # Mosquitto being down is check_docker.sh's job. The log checks above still
    # cover the connection in that case, so stay quiet here rather than guess.
    health_bad=0
    if [ -n "$healthy" ] && [ "$healthy" != "true" ]; then
        health_bad=1
    fi
    # Two consecutive runs, so 30 min, before this alerts. The flag flips false
    # on a single failed Tesla request and this setup sees routine timeouts from
    # Tesla (2026-10-04, -08, -09, -20), which recover on their own.
    flag_alert "unhealthy_${car}" "$health_bad" \
        "🔴 <b>TeslaMate car ${car}</b>: TeslaMate reports the car as unhealthy, it is not getting data from Tesla" \
        "✅ <b>TeslaMate car ${car}</b>: reporting healthy again" 2

    # Idle states (offline, asleep, suspended) write no positions at all, which
    # is why they are not checked. `driving` writes them continuously, so a gap
    # there means data is being lost right now.
    driving_bad=0
    detail=""
    if [ "$state" = "driving" ]; then
        age=$(psql_value "SELECT COALESCE(extract(epoch from (now() - max(date))), 999999)::bigint
                          FROM positions WHERE car_id = ${car};")
        if [ "$age" -gt "$DRIVING_STALE_SECONDS" ]; then
            driving_bad=1
            detail="$((age / 60))min"
        fi
    fi
    flag_alert "driving_gap_${car}" "$driving_bad" \
        "🔴 <b>TeslaMate car ${car}</b>: car is driving but no position logged for ${detail}, trip data is being lost" \
        "✅ <b>TeslaMate car ${car}</b>: driving positions are being logged again"
done
