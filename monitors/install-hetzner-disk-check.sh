#!/usr/bin/env bash
# Install the Hetzner host-local disk check (t1493u, intake 57cf5788).
#
# Run from the machine-management checkout ON HETZNER (RMTHZ) as your normal
# user — never on Contabo:
#   ./monitors/install-hetzner-disk-check.sh
#
# What it does (idempotent):
#   1. Installs hetzner-disk-check.sh to the stable path
#      /usr/local/sbin/hetzner-disk-check.sh (worktrees come and go; the
#      pager must not die with one).
#   2. Creates the state dir ~/.../hetzner-disk-check + samples dir.
#   3. Installs the every-5-min user-cron entry (never duplicates it).
#   4. Runs once live (expect ALL_OK or a real WARN — Hetzner / is ~12% free,
#      so the first real WARN is expected and correct; do NOT raise
#      thresholds to hide it).
#
# Private msmtp setup (by hand, values stay in ~/.secrets, never in git):
#   - ~/.msmtprc (chmod 600) must define account `alerts` sending
#     From DTC Alerts <alerts@dtcdev.click> via SES SMTP.
#   - Test: `echo -e "Subject: disk msmtp test\n\nok" | msmtp -a alerts -- dev@dtcdev.click`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/hetzner-disk-check.sh"
SCRIPT="/usr/local/sbin/hetzner-disk-check.sh"
FAIL=0

echo "== install script to stable path =="
sudo install -m 0755 "$SCRIPT_SRC" "$SCRIPT"
bash -n "$SCRIPT" && echo SYNTAX_OK

echo "== state dirs =="
mkdir -p "$HOME/.local/state/hetzner-disk-check/samples"
echo "state: $HOME/.local/state/hetzner-disk-check"

echo "== mail path =="
if command -v msmtp >/dev/null 2>&1; then
  echo "msmtp present"
  if [[ -f "$HOME/.msmtprc" ]]; then
    echo "~/.msmtprc present ($(stat -c%a "$HOME/.msmtprc"))"
  else
    echo "WARN: ~/.msmtprc MISSING — create it privately; alerts will be LOG-ONLY until then"
  fi
elif command -v sendmail >/dev/null 2>&1; then
  echo "sendmail present (msmtp preferred)"
else
  echo "WARN: no MTA — install msmtp (sudo apt-get install msmtp-mta), then create ~/.msmtprc privately"
  FAIL=1
fi

echo "== user cron (every 5 min) =="
CRON_LINE="*/5 * * * * $SCRIPT >> $HOME/.local/state/hetzner-disk-check/cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "hetzner-disk-check.sh"; then
  if crontab -l 2>/dev/null | grep -qF "$SCRIPT"; then
    echo "cron already installed"
  else
    echo "WARN: an older hetzner-disk-check.sh cron points elsewhere:"
    crontab -l 2>/dev/null | grep -F "hetzner-disk-check.sh"
    echo "remove the stale line with 'crontab -e', then re-run this installer"
    FAIL=1
  fi
else
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "cron installed: $CRON_LINE"
fi

echo "== first run (live, no drill) =="
bash "$SCRIPT" || echo "(exit $?: investigate real findings above — a WARN on / is expected, do NOT mask it)"

if [[ "$FAIL" -ne 0 ]]; then
  echo "NEXT: fix WARNs above, then re-run this installer."
  exit 1
fi
echo "NEXT: prove the drill path with DISK_DRILL=1 (mail to ${ALERT_OPS_TO:-dev@dtcdev.click} only), then clear it."
