#!/bin/bash
set -euo pipefail

# Weekly check for third-party container images that have been rebuilt upstream
# since we pulled them. Notify-only, deliberately: Authelia, TeslaMate and UniFi
# all run migrations on startup, so updates get applied by hand, not unattended.
#
# Run with --seed to record the current state without notifying, for when a
# backlog is already known and only new drift is interesting.

source /home/sntr/.telegram_alert.env

STATE_DIR="/home/sntr/scripts"
SEED=0
[ "${1:-}" = "--seed" ] && SEED=1

source /home/sntr/git/sntrserv-monitoring/lib/notify.sh

# Our own CI-built images are skipped. They're deployed by pushing, so the
# registry being ahead of the container is a deploy question, not an update one.
is_ours() {
    case "$1" in
        ghcr.io/sntr8/*) return 0 ;;
        *) return 1 ;;
    esac
}

checked=0
failed=0

for img in $(docker ps --format '{{.Image}}' | sort -u); do
    is_ours "$img" && continue

    # Locally built images have no RepoDigests, so there is nothing to compare
    # them against. That skips the patchwork :dev images.
    local_digest=$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | cut -d@ -f2)
    [ -z "$local_digest" ] && continue

    checked=$((checked + 1))
    remote_digest=$(timeout 30 docker buildx imagetools inspect "$img" --format '{{.Manifest.Digest}}' 2>/dev/null || true)

    # A single registry hiccup must not look like an update, so skip this image.
    # Widespread failure is reported after the loop instead: Docker Hub rate
    # limits anonymous manifest requests, and a check that silently stops
    # checking is worse than no check.
    if [ -z "$remote_digest" ]; then
        failed=$((failed + 1))
        continue
    fi

    state_file="${STATE_DIR}/.image_alerted_$(echo "$img" | tr '/:' '__')"

    if [ "$local_digest" != "$remote_digest" ]; then
        if [ "$SEED" -eq 1 ]; then
            touch "$state_file"
        elif [ ! -f "$state_file" ]; then
            notify "⚠️ <b>${img}</b>: newer image published upstream, container is running an older build"
            touch "$state_file"
        fi
    else
        if [ "$SEED" -eq 1 ]; then
            rm -f "$state_file"
        elif [ -f "$state_file" ]; then
            notify "✅ <b>${img}</b>: now running the current published image"
            rm -f "$state_file"
        fi
    fi
done

# Report the check itself being broken, once, with the same alert-state pattern.
degraded_file="${STATE_DIR}/.image_check_degraded"
if [ "$checked" -gt 0 ] && [ "$failed" -ge "$(( (checked + 1) / 2 ))" ]; then
    if [ "$SEED" -eq 0 ] && [ ! -f "$degraded_file" ]; then
        notify "🔴 <b>image update check</b>: ${failed}/${checked} registry lookups failed, results are incomplete"
    fi
    touch "$degraded_file"
elif [ -f "$degraded_file" ]; then
    [ "$SEED" -eq 0 ] && notify "✅ <b>image update check</b>: registry lookups working again"
    rm -f "$degraded_file"
fi
