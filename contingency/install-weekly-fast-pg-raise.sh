#!/usr/bin/env bash
# Install weekly raise cron on Hetzner (run on Hetzner as root or sudo).
set -euo pipefail
REPO="${REPO:-/home/alexey/git/machine-management}"
install -d -o alexey -g alexey /home/alexey/.local/state/dr-fast-pg-raise
install -m 0644 "$REPO/contingency/weekly-fast-pg-raise.cron" /etc/cron.d/weekly-fast-pg-raise
chmod 0755 "$REPO/contingency/weekly-fast-pg-raise.sh" \
  "$REPO/contingency/push-dr-raise-metrics.sh" \
  "$REPO/contingency/fast-pg-raise.sh"
echo "installed /etc/cron.d/weekly-fast-pg-raise"
