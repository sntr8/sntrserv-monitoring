#!/bin/bash
set -euo pipefail

source /home/sntr/.monitoring.env

curl -fsS --max-time 10 "$HC_PING_URL" >/dev/null
