#!/usr/bin/env bash
# Install the scheduled self-hosted GitHub Actions runner monitor on Hetzner
# (RMTHZ) as a user cron job every 5 minutes.
#
# Usage (on Hetzner RMTHZ):
#   ./monitors/install-gha-runner-monitor.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="${HERE}/gha-runner-monitor.sh"
SCRIPT="/usr/local/sbin/gha-runner-monitor.sh"

echo "== installing gha-runner-monitor.sh to ${SCRIPT} =="
sudo install -m 0755 "$SCRIPT_SRC" "$SCRIPT"
sudo install -m 0644 "${HERE}/relay-alert-lib.sh" /usr/local/sbin/relay-alert-lib.sh
bash -n "$SCRIPT" && echo "SYNTAX_OK"

echo "== creating state dir =="
mkdir -p "$HOME/.local/state/gha-runner-monitor"

echo "== installing user cron (every 5 min) =="
CRON_LINE="*/5 * * * * PATH=/home/alexey/.local/bin:/usr/local/bin:/usr/bin:/bin ${SCRIPT} >> ${HOME}/.local/state/gha-runner-monitor/cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "gha-runner-monitor.sh"; then
  if crontab -l 2>/dev/null | grep -qF "$SCRIPT"; then
    echo "cron already installed"
  else
    echo "WARN: existing gha-runner-monitor.sh cron points elsewhere; update manually" >&2
    exit 1
  fi
else
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "cron installed: $CRON_LINE"
fi
