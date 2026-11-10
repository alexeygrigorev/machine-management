#!/usr/bin/env bash
# Install the merged app-owned poller without changing its release authority.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${CMP_REPO:-$HOME/git/course-management-platform}"
revision="$(git -C "$repo" rev-parse origin/main)"
destination="$HOME/.local/lib/cmp-release-poller/$revision"
mkdir -p "$destination" "$HOME/.config/systemd/user" "$HOME/.local/state"
git -C "$repo" show "$revision:deploy/coolify/hetzner-rollout.sh" > "$destination/hetzner-rollout.sh"
bash -n "$destination/hetzner-rollout.sh"
chmod 0755 "$destination/hetzner-rollout.sh"
ln -sfn "$revision" "$HOME/.local/lib/cmp-release-poller/current"
for unit in cmp-release-poller.service cmp-release-poller.timer; do
  install -m 0644 "$here/$unit" "$HOME/.config/systemd/user/$unit"
done
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
crontab -l > "$HOME/.local/state/crontab.pre-cmp-poller-$stamp"
python3 - "$HOME/.local/state/crontab.pre-cmp-poller-$stamp" <<'PY' | crontab -
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.lstrip().startswith('#') or 'hetzner-rollout.sh' not in line:
        print(line)
PY
systemctl --user daemon-reload
systemctl --user enable --now coolify-api-tunnel.service
systemctl --user enable cmp-release-poller.timer
echo "Installed CMP poller from merged $revision; start its timer after verification."
