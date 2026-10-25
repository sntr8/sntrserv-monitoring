#!/bin/bash
# Single source of truth for the public sites fronted by Corsair.
#
# Both check_sites.sh (is it responding) and check_certs.sh (is its TLS cert
# about to expire) read this list, so the two cannot drift apart when a site is
# added or retired.
#
# Format: domain|expected_http_code
#
# The expected code is what the site returns today, verified 2026-10-22, not
# what it ideally should return. Anything else is treated as an outage.

SITES=(
    "workform.erikoispumppaus.fi|200"   # revenue site
    "kivikarinkuja.sntrserv.net|200"
    "techdemo.saaresti.eu|200"
    "lunchy.sntrserv.net|200"
    "lxdesigns.fi|200"
    "palealderandsleeves.com|200"
    "kuvat.lehtone.nl|200"
    "corsair.sntrserv.net|200"
    "auth.sntrserv.net|200"

    # Authelia forward-auth sends anonymous requests to the login page.
    "tesla.sntrserv.net|302"
    # Redirects to its own /manage path.
    "unifi.sntrserv.net|302"
    # Retired 2026-10-22, now a permanent redirect to palealderandsleeves.com.
    "sleeves.sntrserv.net|301"

    # KNOWN BROKEN: 404 is app-level routing that predates the monitoring and
    # has nothing to do with the proxy. Recorded as 404 so the check reflects
    # reality instead of alerting forever. Tighten this to 200 once fixed.
    "patchwork.sntrserv.net|404"
)

# site_domains: prints just the domain part, one per line.
site_domains() {
    local entry
    for entry in "${SITES[@]}"; do
        printf '%s\n' "${entry%%|*}"
    done
}
