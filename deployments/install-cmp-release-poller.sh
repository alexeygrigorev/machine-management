#!/usr/bin/env bash
# Install the merged app-owned poller without changing its release authority.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# POLLER_HOME selects the operator installation when the calling engine has an
# isolated provider HOME. Do not change HOME or any runtime secret locations.
operator_home="${POLLER_HOME:-$HOME}"
repo="${CMP_REPO:-$operator_home/git/course-management-platform}"
revision="$(git -C "$repo" rev-parse "${CMP_REVISION:-origin/main}^{commit}")"
git -C "$repo" merge-base --is-ancestor "$revision" origin/main || {
  echo "Refusing an unmerged CMP poller revision" >&2; exit 1;
}
destination="$operator_home/.local/lib/cmp-release-poller/$revision"
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup="$operator_home/.local/state/cmp-poller-backup-$stamp"
mkdir -p "$backup"
for prior in "$operator_home/.local/lib/cmp-release-poller/current" "$operator_home/.config/systemd/user/cmp-release-poller.service" "$operator_home/.config/systemd/user/cmp-release-poller.timer"; do
  if [[ -e "$prior" ]]; then cp -a "$prior" "$backup/"; fi
done
if [[ -e "$operator_home/.local/lib/cmp-release-poller/current/hetzner-rollout.sh" ]]; then
  cp -p "$operator_home/.local/lib/cmp-release-poller/current/hetzner-rollout.sh" "$backup/previous-hetzner-rollout.sh"
fi
mkdir -p "$destination" "$operator_home/.config/systemd/user" "$operator_home/.local/state"
candidate=""
trap '[[ -z "$candidate" ]] || rm -f -- "$candidate"' EXIT
candidate="$(mktemp "$destination/.candidate.XXXXXX")"
git -C "$repo" show "$revision:deploy/coolify/hetzner-rollout.sh" > "$candidate"
bash -n "$candidate"
if [[ -f "$destination/hetzner-rollout.sh" ]]; then
  cmp -s "$candidate" "$destination/hetzner-rollout.sh" || {
    echo "Refusing to overwrite an existing immutable revision" >&2; exit 1;
  }
else
  install -m 0755 "$candidate" "$destination/hetzner-rollout.sh"
fi
ln -s "$revision" "$operator_home/.local/lib/cmp-release-poller/current.$stamp"
mv -Tf "$operator_home/.local/lib/cmp-release-poller/current.$stamp" "$operator_home/.local/lib/cmp-release-poller/current"
for unit in cmp-release-poller.service cmp-release-poller.timer cmp-release-poller-failure.service; do
  install -m 0644 "$here/$unit" "$operator_home/.config/systemd/user/$unit"
done
crontab -l > "$operator_home/.local/state/crontab.pre-cmp-poller-$stamp"
python3 - "$operator_home/.local/state/crontab.pre-cmp-poller-$stamp" <<'PY' | crontab -
import pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.lstrip().startswith('#') or 'hetzner-rollout.sh' not in line:
        print(line)
PY
systemctl --user daemon-reload
systemctl --user enable --now coolify-api-tunnel.service
systemctl --user enable cmp-release-poller.timer
echo "Installed CMP poller from merged $revision; rollback snapshot: $backup. Start its timer after verification."
