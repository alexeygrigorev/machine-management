#!/usr/bin/env bash
# Install files only. This does not run GC or remove existing data.
set -euo pipefail
host_short="$(hostname -s 2>/dev/null || hostname)"
[[ "${host_short,,}" == *rmthz* ]] || { echo "Refusing: this installer is for RMTHZ; host is $host_short" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
install -d -m 0755 "$DEST" "$UNIT_DIR"
install -d -m 0700 "$HOME/.local/state/rmthz-disk-gc"
install -d -m 0755 "$HOME/tmp/agent-reports"
install -m 0755 "$HERE/rmthz-disk-gc.sh" "$DEST/rmthz-disk-gc.sh"
install -m 0644 "$HERE/rmthz-disk-gc.service" "$UNIT_DIR/rmthz-disk-gc.service"
install -m 0644 "$HERE/rmthz-disk-gc-daily.service" "$UNIT_DIR/rmthz-disk-gc-daily.service"
install -m 0644 "$HERE/rmthz-disk-gc-daily.timer" "$UNIT_DIR/rmthz-disk-gc-daily.timer"
systemctl --user daemon-reload
systemctl --user enable --now rmthz-disk-gc-daily.timer
echo "Installed in dry-run mode. Review ~/.local/state/rmthz-disk-gc and ~/tmp/agent-reports."
echo "Set RMTHZ_GC_MODE=apply in ~/.config/rmthz-disk-gc.env only after Alexey approves the dry-run list."
echo "Run once: $DEST/rmthz-disk-gc.sh --dry-run --trigger manual"
