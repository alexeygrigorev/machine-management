#!/usr/bin/env bash
# Install stale-check on contabo-a (run as root on contabo-a).
set -euo pipefail
SRC="${SRC:-/tmp/dr-raise-stale-check}"
install -m 0755 "$SRC/dr-raise-stale-check.sh" /usr/local/sbin/dr-raise-stale-check.sh
install -m 0644 "$SRC/dr-raise-stale-check.cron" /etc/cron.d/dr-raise-stale-check
mkdir -p /var/lib/dr-raise-stale-check
touch /var/log/dr-raise-stale-check.log
# Preserve operator-owned recipients on reinstall.
if [[ ! -f /etc/dr-raise-stale-check.env ]]; then
  echo "ALERT_TO=alexey@datatalks.club,dev@dtcdev.click" > /etc/dr-raise-stale-check.env
fi
chmod 600 /etc/dr-raise-stale-check.env
echo "installed stale-check on $(hostname)"
