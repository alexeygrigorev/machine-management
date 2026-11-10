#!/usr/bin/env bash
# Install committed helpers; the production timer never runs a mutable checkout.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
revision="$(git -C "$here" rev-parse HEAD)"
git -C "$here" diff --quiet HEAD -- deployments
destination="$HOME/.local/lib/coolify-rolling-web/$revision"
mkdir -p "$destination" "$HOME/.config/systemd/user" "$HOME/.local/state"
for file in coolify-rolling-web.py coolify-rolling-web.json; do
  install -m 0644 "$here/$file" "$destination/$file"
done
install -m 0755 "$here/rolling-follower-failure.sh" "$destination/rolling-follower-failure.sh"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "$HOME/.config/coolify-rolling-web.json" ]]; then
  cp -p "$HOME/.config/coolify-rolling-web.json" "$HOME/.config/coolify-rolling-web.json.bak-$stamp"
fi
install -m 0600 "$destination/coolify-rolling-web.json" "$HOME/.config/coolify-rolling-web.json"
ln -sfn "$revision" "$HOME/.local/lib/coolify-rolling-web/current"
for unit in coolify-api-tunnel.service coolify-rolling-web.service coolify-rolling-web.timer coolify-rolling-web-failure.service; do
  install -m 0644 "$here/$unit" "$HOME/.config/systemd/user/$unit"
done
crontab -l > "$HOME/.local/state/crontab.pre-follower-$stamp"
python3 - "$HOME/.local/state/crontab.pre-follower-$stamp" <<'PY' | crontab -
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if 'coolify-rolling-web.py' not in line:
        print(line)
PY
systemctl --user daemon-reload
systemctl --user enable --now coolify-api-tunnel.service
# The caller starts the timer after a one-app-at-a-time acceptance rollout.
systemctl --user enable coolify-rolling-web.timer
echo "Installed revision $revision; timer enabled but not started."
