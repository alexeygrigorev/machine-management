#!/usr/bin/env bash
# Install the DR raise stale-check on Hetzner (run with sudo from a fresh
# origin/main checkout or worktree). The check runs where the DR series
# live: the Hetzner loopback VM (400d) fed by push-dr-raise-metrics.sh.
#
# The env file holds no secrets: recipients, VM URL and the paths of the
# operator's existing Relay client config (0600, never copied or printed).
set -euo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUN_USER="${RUN_USER:-alexey}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
install -m 0755 "$REPO/monitors/dr-raise-stale-check.sh" /usr/local/sbin/dr-raise-stale-check.sh
install -m 0644 "$REPO/monitors/dr-raise-stale-check.cron" /etc/cron.d/dr-raise-stale-check
# Production state dir: the script only treats /var/lib/dr-raise-stale-check
# as live (any other STATE_DIR strips personal recipients).
install -d -o "$RUN_USER" -g "$RUN_USER" -m 0755 /var/lib/dr-raise-stale-check
install -d -o "$RUN_USER" -g "$RUN_USER" "$RUN_HOME/.local/state/dr-raise-stale-check"
# Preserve operator-owned recipients on reinstall.
if [[ ! -f /etc/dr-raise-stale-check.env ]]; then
  cat > /etc/dr-raise-stale-check.env <<ENV
ALERT_TO=alexey@datatalks.club,dev@dtcdev.click
VM_URL=http://127.0.0.1:8428
RELAY_MONITOR_CONFIG=${RUN_HOME}/.config/datamailer/config.toml
DATAMAILER_BIN=${RUN_HOME}/.local/bin/datamailer
ENV
fi
chown root:"$RUN_USER" /etc/dr-raise-stale-check.env
chmod 0640 /etc/dr-raise-stale-check.env
echo "installed stale-check on $(hostname) (rev $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown))"
