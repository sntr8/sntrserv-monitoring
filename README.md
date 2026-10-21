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

## Components

- **`scripts/heartbeat-ping.sh`** — run every 5 min via cron on each host. Pings
  that host's healthchecks.io check. If a host misses two check-ins in a row,
  healthchecks.io fires its "down" webhook, which posts straight to our Telegram
  bot (see below) instead of using healthchecks.io's own bot.
- **`scripts/check_php_patch.sh`** — runs every 15 min on Vampire. Checks Corsair
  for the PHP 8.3.36 security fix (CVE-2026-109618 / CVE-2026-109619) via
  `dnf check-update` over SSH, and Telegram-notifies once when it becomes
  available. Temporary — remove once Corsair is patched and this isn't a live
  concern anymore.
- **`scripts/check_disk.sh`** — runs every 15 min on Vampire only. Checks root
  disk usage on both Vampire (locally) and Corsair (via SSH), alerts via
  Telegram if either crosses 85%, clears when back under. Direct Telegram
  alerting, no healthchecks.io involved — this doesn't need a dead-man's-switch
  since Vampire running the cron at all proves Vampire is up.
- **`scripts/check_resources.sh`** — runs every 5 min on Vampire only, checks
  CPU load and memory on both Vampire (locally) and Corsair (via SSH). Load is
  compared as a ratio to core count (threshold 1.5x), memory as % available
  (threshold 15%). Requires 3 consecutive breaches before alerting, to avoid
  noise from brief spikes — effectively a ~15 min sustained-condition check.
  Direct Telegram alerting, same reasoning as `check_disk.sh`.
- **`scripts/check_erikoispumppaus.sh`** — runs every 5 min on Vampire. Curls
  the real public URL `https://workform.erikoispumppaus.fi` (revenue-generating
  site) and alerts directly via Telegram if it's not a 200, clears on recovery.
  Deliberately *not* routed through healthchecks.io — this complements the
  heartbeat rather than duplicating it: the heartbeat catches "server is down,"
  this catches "server is up but the app/site itself is broken" (container
  crash, bad vhost, expired cert, DB issue, etc.), and Vampire running this
  cron at all already proves Vampire itself is up.

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
- **`scripts/check_teslamate.sh`** — every 15 min on Vampire. Queries the
  `positions` table in `teslamate-database-1` directly for the most recent
  timestamp; alerts if the car hasn't reported in 24h+ (the original 2026-06-22
  incident: the car silently stopped reporting for an unknown period before
  anyone noticed manually).
- **`scripts/check_certs.sh`** — every 6h on Vampire. Checks real TLS cert
  expiry (via `openssl s_client` against the live port 443, not reading files)
  for every public site on Corsair plus `tesla.sntrserv.net`. Catches a silent
  certbot/Traefik renewal failure before it becomes an outage. Threshold 14
  days.
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
*/15 * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_php_patch.sh
*/5  * * * * /home/sntr/git/sntrserv-monitoring/scripts/check_erikoispumppaus.sh
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
