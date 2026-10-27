#!/usr/bin/env bash
# Install the Storagebox staleness dead-man on HETZNER (t1553u).
#
# Run from the machine-management checkout ON HETZNER as alexey:
#   ./monitors/install-storagebox-staleness-check.sh
#
# What it does (idempotent):
#   1. Installs storagebox-staleness-check.sh to the stable path
#      /usr/local/sbin/storagebox-staleness-check.sh (worktrees come and go;
#      the pager must not die with one).
#   2. Creates the state dir ~/.local/state/storagebox-sync.
#   3. Installs the twice-daily user-cron entry (never duplicates it).
#   4. Runs once live (expect FAIL while the mirror is stale since 23 Oct —
#      that FAIL is correct and must page; do NOT mute it).
#
# Private msmtp setup (by hand, values stay in ~/.secrets, never in git):
#   - ~/.msmtprc (chmod 600) must define account `alerts` sending
#     From DTC Alerts <alerts@dtcdev.click> via SES SMTP (same as
#     coolify-healthcheck / hetzner-disk-check).
#   - Drill: `STORAGEBOX_STALE_DRILL=1 /usr/local/sbin/storagebox-staleness-check.sh`
#     pages dev@dtcdev.click only; re-run without it to clear.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/storagebox-staleness-check.sh"
SCRIPT="/usr/local/sbin/storagebox-staleness-check.sh"
CRON_SRC="$HERE/storagebox-staleness-check.cron"
FAIL=0

echo "== install script to stable path =="
sudo install -m 0755 "$SCRIPT_SRC" "$SCRIPT"
bash -n "$SCRIPT" && echo SYNTAX_OK

echo "== state dir =="
mkdir -p "$HOME/.local/state/storagebox-sync"
touch "$HOME/.local/state/storagebox-sync/staleness.log"
echo "state: $HOME/.local/state/storagebox-sync"

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

echo "== user cron (twice daily 06:00,18:00 Europe/Berlin) =="
CRON_LINE='0 6,18 * * * /usr/local/sbin/storagebox-staleness-check.sh >> /home/alexey/.local/state/storagebox-sync/staleness.log 2>&1'
if crontab -l 2>/dev/null | grep -qF "storagebox-staleness-check.sh"; then
  if crontab -l 2>/dev/null | grep -qF "/usr/local/sbin/storagebox-staleness-check.sh"; then
    echo "cron already installed"
  else
    echo "WARN: an older storagebox-staleness-check.sh cron points elsewhere:"
    crontab -l 2>/dev/null | grep -F "storagebox-staleness-check.sh"
    echo "remove the stale line with 'crontab -e', then re-run this installer"
    FAIL=1
  fi
else
  # Pin Europe/Berlin for this job only: user crontabs here already set
  # CRON_TZ=UTC mid-file, so a top-level TZ is not reliable. A CRON_TZ line
  # immediately before the job covers it regardless of earlier assignments.
  TMP_CRON="$(mktemp)"
  trap 'rm -f "$TMP_CRON"' EXIT
  crontab -l 2>/dev/null > "$TMP_CRON" || true
  printf 'CRON_TZ=Europe/Berlin\n%s\n' "$CRON_LINE" >> "$TMP_CRON"
  crontab "$TMP_CRON"
  rm -f "$TMP_CRON"
  trap - EXIT
  echo "cron installed: CRON_TZ=Europe/Berlin + $CRON_LINE"
fi

echo "== reference cron file =="
cat "$CRON_SRC"

echo "== first run (live, no drill) =="
bash "$SCRIPT" || echo "(exit $?: stale FAIL is expected until the mirror runs fresh — do NOT mute it)"

if [[ "$FAIL" -ne 0 ]]; then
  echo "NEXT: fix WARNs above, then re-run this installer."
  exit 1
fi
echo "NEXT: prove the drill path with STORAGEBOX_STALE_DRILL=1 (mail to dev@dtcdev.click only), then clear it."
