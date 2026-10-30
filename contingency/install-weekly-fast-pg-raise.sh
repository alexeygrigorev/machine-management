#!/usr/bin/env bash
# Install the weekly raise + hourly metrics mirror on Hetzner (run with sudo
# from a fresh origin/main checkout or worktree).
#
# Copies the scripts to a stable /usr/local/lib/dr-fast-pg-raise/contingency/
# so cron never executes a git checkout that may lag origin/main or carry
# someone else's uncommitted work (68147e6c AC6). Re-run after every change
# to these scripts.
set -euo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="${DEST:-/usr/local/lib/dr-fast-pg-raise}"
install -d -o alexey -g alexey /home/alexey/.local/state/dr-fast-pg-raise
install -d -m 0755 "$DEST/contingency"
for f in weekly-fast-pg-raise.sh fast-pg-raise.sh push-dr-raise-metrics.sh mirror-dr-raise-metrics.sh; do
  install -m 0755 "$REPO/contingency/$f" "$DEST/contingency/$f"
done
git -C "$REPO" rev-parse HEAD > "$DEST/REVISION" 2>/dev/null || echo unknown > "$DEST/REVISION"
install -m 0644 "$REPO/contingency/weekly-fast-pg-raise.cron" /etc/cron.d/weekly-fast-pg-raise
install -m 0644 "$REPO/contingency/dr-raise-metrics-mirror.cron" /etc/cron.d/dr-raise-metrics-mirror
echo "installed $DEST (rev $(cat "$DEST/REVISION")) + /etc/cron.d/{weekly-fast-pg-raise,dr-raise-metrics-mirror}"
