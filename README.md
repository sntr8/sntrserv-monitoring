# sntrserv monitoring

Lightweight monitoring for Vampire and Corsair. No AI, no cloud monitoring stack,
just cron + curl + Telegram.

## Important constraint: Corsair cannot reach api.telegram.org

Confirmed 2026-10-21: Corsair's outbound HTTPS to `api.telegram.org` completes a
full TLS handshake (valid cert, real Telegram IP) and then just hangs — no
response, ever. Everything else outbound from Corsair works fine, including
`hc-ping.com`. Most likely Telegram silently blackholing Corsair's IP (reputation
filtering on a hosting-provider range that's constantly scanned/attacked — see
the fail2ban entries in its firewall), not a local config issue.

**Rule for any future script: a Telegram message must be sent from Vampire.**
If the thing being checked lives on Corsair, SSH into Corsair to gather data,
then `curl` the Telegram API from Vampire — never deploy a Telegram-sending
script to run directly on Corsair, it'll silently fail to notify.
`hc-ping.com` calls are fine to run directly on Corsair, that path works.

## Message format

All direct-Telegram alerts (everything except the healthchecks.io-routed
heartbeat) go through the shared `lib/notify.sh`, which sends with
`parse_mode=HTML`. Every message follows `<emoji> <b>IDENTIFIER</b>: detail`
— 🔴 for a real failure, ⚠️ for a threshold crossed, ✅ for recovery.
IDENTIFIER is whatever's most specific to the problem (host name, container
name, domain, service name). Keep new checks consistent with this.

## Shared libraries

- **`lib/notify.sh`** — the one Telegram sender. Every direct alert goes
  through it so the message format stays consistent in one place.
- **`lib/tiers.sh`** — `tiered_alert()`, for metrics that keep getting worse.
  The boolean state-file pattern the other checks use is right for a binary
  condition (container down, backup stale) but wrong for a continuous value: it
  alerts once on crossing and then goes silent, so a disk filling from 85% to
  100% produced exactly one message. This stores the severity *tier* instead of
  a boolean and alerts once per tier crossed, escalating only, never repeating
  or de-escalating, so a value wobbling on a boundary stays quiet. Each tier
  carries its own consecutive-breach dampener.
- **`lib/sites.sh`** — the single list of public sites, as
  `domain|expected_http_code`. Both `check_sites.sh` and `check_certs.sh` read
  it, so the uptime list and the cert list cannot drift apart when a site is
  added or retired. The expected code is what the site returns *today*, not what
  it ideally should: `tesla` and `unifi` are 302, `sleeves` is 301, and
  `patchwork` is 404 because of a pre-existing app routing bug.

## Components

- **`scripts/heartbeat-ping.sh`** — run every 5 min via cron on each host. Pings
  that host's healthchecks.io check. If a host misses two check-ins in a row,
  healthchecks.io fires its "down" webhook, which posts straight to our Telegram
  bot (see below) instead of using healthchecks.io's own bot.
- **`scripts/check_disk.sh`** — runs every 15 min on Vampire only. Checks root
  disk usage on both Vampire (locally) and Corsair (via SSH). Tiered via
  `lib/tiers.sh` at 85/90% ⚠️ and 95/98% 🔴, so a disk that keeps filling keeps
  reporting instead of going quiet after the first crossing. Disk moves slowly
  and never spikes, so every tier alerts on the first breach. Direct Telegram
  alerting, no healthchecks.io involved: this doesn't need a dead-man's-switch
  since Vampire running the cron at all proves Vampire is up.
- **`scripts/check_resources.sh`** — runs every 5 min on Vampire only, checks
  CPU load, memory and swap on both Vampire (locally) and Corsair (via SSH),
  all tiered via `lib/tiers.sh`. Load is a ratio to core count (1.5x ⚠️, 3x/5x
  🔴), memory is % available (15/10% ⚠️, 5% 🔴), swap is % in use (60/80% ⚠️,
  95% 🔴). The mild tiers keep the 3-consecutive-breach dampener, since a
  5-min load average crossing 1.5x once is usually a build or a backup; the
  severe tiers drop to 1, because a host with 5% memory left can be dead before
  three checks have run. Swap is a soft signal on its own (Linux leaves idle
  pages there harmlessly) but moves earlier than MemAvailable, which only drops
  once swap is already exhausted; Corsair has no swap at all, so that check
  guards against dividing by zero and skips it there. Direct Telegram alerting,
  same reasoning as `check_disk.sh`.
- **`scripts/check_sites.sh`** — runs every 5 min on Vampire. Curls every
  domain in `lib/sites.sh` and alerts if the response code isn't the expected
  one, clears on recovery. Up/down is binary, so this keeps the boolean
  state-file pattern rather than the tiered one. Deliberately *not* routed
  through healthchecks.io: it complements the heartbeat rather than duplicating
  it, since the heartbeat catches "server is down" and this catches "server is
  up but the app itself is broken" (container crash, bad vhost, DB issue), and
  Vampire running this cron at all already proves Vampire is up.

  **Replaced `check_erikoispumppaus.sh` on 2026-10-22.** That script curled only
  the one revenue site, so any of the other 12 domains returning a 500 was
  invisible, even though certs were already being checked for all of them. The
  old script and its cron entry were removed at the same time, to avoid
  duplicate alerts for erikoispumppaus.

## Secrets (never committed)

Each host needs its own `/home/sntr/.monitoring.env` (its healthchecks.io ping
URL) and, where Telegram notifications are sent from, `/home/sntr/.telegram_alert.env`
(bot token + chat ID). See `.env.example` for the shape. Both files are `chmod 600`.

## healthchecks.io setup

Two checks: `vampire-heartbeat`, `corsair-heartbeat`. Period 5 min, grace 10 min.
Notifications go through the **Webhook** integration (not the built-in Telegram
integration, which is locked to healthchecks.io's own bot) pointed at our bot:

- Method: POST
- URL: `https://api.telegram.org/bot<TOKEN>/sendMessage`
- Header: `Content-Type: application/x-www-form-urlencoded`
- Body (down): `chat_id=<CHAT_ID>&text=\U0001f534 $NAME is DOWN since $NOW`
- Body (up): `chat_id=<CHAT_ID>&text=✅ $NAME recovered at $NOW`

- **`scripts/check_docker.sh`** — every 5 min on Vampire. Flags any container
  whose status isn't `Up...` or contains `(unhealthy)`. Per-container alert
  state, so a crash alerts once and a recovery clears it. Caveat: if you
  intentionally stop a container for maintenance, this will alert and keep
  alerting until it's running again — no "pause" mechanism built, kept simple
  for v1.
- **`scripts/check_teslamate.sh`** — every 15 min on Vampire. Asks whether
  TeslaMate's connection to Tesla is working, which is a different question from
  whether the car has moved. Three independent conditions, each with its own
  alert state:
  1. No Tesla token refresh logged in 8h. TeslaMate refreshes at 6h and logs
     almost nothing else while the car is offline, so this is its proof of life
     and its proof that auth still works. Suppressed if the container started
     inside the window and has not had time to log one.
  2. Three or more forbidden/unauthorized responses on outbound Tesla API calls
     in 2h. This is the 2026-06-22 signature. Matching is restricted to lines
     naming a Tesla host, because TeslaMate also logs the requests it serves;
     plain timeouts from Tesla are routine and deliberately do not match.
  3. TeslaMate's own MQTT `healthy` flag reporting false, read from Mosquitto.
     A missing flag is treated as unknown, not as a fault, since Mosquitto being
     down is `check_docker.sh`'s job.

  Position freshness is only consulted when the car reports `driving`, where a
  gap means trip data is being lost right now.

  **It no longer alerts on an idle car**, which is what the original version
  did. That version alerted when `positions` had no new row in 24h, and was
  wrong in both directions. TeslaMate only writes positions while the car is
  awake, so every normal parked day or week raised an alert; and during the
  2026-06-22 outage the streaming ingest kept writing positions the whole time
  (only the REST path, and so the `drives` rollup, was broken), so the check
  would have stayed silent through the one incident it existed to catch.

  This matters more than a stale dashboard: TeslaMate is the e-logbook for
  kilometrikorvaus filing, so an unrecorded trip is lost data.
- **`scripts/check_certs.sh`** — every 6h on Vampire. Checks real TLS cert
  expiry (via `openssl s_client` against the live port 443, not reading files)
  for every domain in `lib/sites.sh`. Catches a silent certbot/Traefik renewal
  failure before it becomes an outage. Tiered at 14 days ⚠️ ("certbot has had a
  chance and should have renewed by now") and 3 days 🔴 ("this is about to break
  in public"). A host that doesn't respond at all is `check_sites.sh`'s job to
  report, so this skips it rather than alerting twice.
- **`scripts/check_backups.sh`** — daily at 10:30 (backups run at 03:00).
  Checks the S3 bucket for both the `vampire/` and `corsair/` prefixes: alerts
  if the latest dated folder is >36h old (missed backup) or contains a
  zero-byte file (corrupted/failed dump).

- **`scripts/check_reboot.sh`** — daily at 20:00 on Vampire, checks both hosts
  via `needs-restarting -r`. Alerts if a kernel/glibc/systemd update is pending
  a reboot to take effect, clears once rebooted. Added 2026-10-22 alongside
  switching `dnf-automatic` from `upgrade_type = security` (effectively a
  no-op on CentOS Stream — see below) to `upgrade_type = default`, so updates
  actually apply continuously; this is the one thing that can't be automated
  away, since an unattended reboot on a live box is its own risk.

- **`scripts/check_image_updates.sh`** — weekly, Mondays at 09:00 on Vampire.
  Compares each running container's image digest against the one its tag now
  points to in the registry, and alerts when upstream has published a newer
  build. Notify-only on purpose: Authelia, TeslaMate and UniFi all run schema
  or config migrations on startup, so an unattended bump at 03:00 is its own
  risk. Added 2026-10-22 after a reboot turned up images up to 14 months old.
  Skips our own `ghcr.io/sntr8/*` images (registry ahead of container there is
  a deploy question, not an update one) and the locally built `patchwork:dev`
  images, which have no registry digest to compare. Takes `--seed` to record
  current state silently, for when the backlog is already known.

  **Known limitation:** this detects a *tag being rebuilt*, not a newer version
  existing under a different tag. Two real cases it misses: `jacobalberty/unifi`
  is pinned to `v9.3.45` and that publisher stopped pushing to Docker Hub in
  December 2025, and `teslamate/teslamate:latest` matches the registry while
  TeslaMate's own logs report 4.0.1 vs 4.3.0 available. Major-version drift
  still needs an occasional manual look; this catches the security rebuilds.

  Docker Hub rate-limits anonymous manifest requests (HTTP 429). Nine images
  once a week is far inside that, but the script counts failed lookups and
  alerts if half or more fail, so a throttled or broken check can't go quiet.

### dnf-automatic note

Both hosts have `dnf-automatic-install.timer` enabled (daily ~6am,
`apply_updates = yes`), but it was set to `upgrade_type = security` — which,
on CentOS Stream, never matched anything (logs showed "No security updates
needed" every single day for months despite 268-323 regular updates sitting
available, because Stream doesn't carry the same security-advisory metadata
RHEL/Alma do). Changed to `upgrade_type = default` 2026-10-22 so it actually
patches. Trade-off: no more human review of what's being applied before it
lands — accepted deliberately, the user wasn't doing that review anyway.

## Cron entries

Vampire:
```
*/5  * * * * /home/sntr/git/sntrserv-monitoring/scripts/heartbeat-ping.sh
*/5  * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_sites.sh
*/15 * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_disk.sh
*/5  * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_resources.sh
*/5  * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_docker.sh
*/15 * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_teslamate.sh
0 */6 * * * /home/sntr/git/sntrserv-monitoring/scripts/check_certs.sh
30 10 * * * /home/sntr/git/sntrserv-monitoring/scripts/check_backups.sh
0 20 * * * /home/sntr/git/sntrserv-monitoring/scripts/check_reboot.sh
0 9  * * 1 /home/sntr/git/sntrserv-monitoring/scripts/check_image_updates.sh
```

Corsair:
```
*/5  * * * * /home/sntr/scripts/heartbeat-ping.sh
```

Note: Corsair runs its own standalone copy of `heartbeat-ping.sh` at
`/home/sntr/scripts/` (deployed via `scp`, not a git checkout) since it only
needs that one script and doesn't otherwise need a full clone of this repo.
