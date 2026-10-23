#!/usr/bin/env bash
# Install the off-Contabo dead-man on a Hetzner/operator box (t1143u).
#
# Run from the machine-management checkout ON THE BOX THAT WILL PAGE
# (e.g. Hetzner RMTHZ) as your normal user — never on contabo-a/contabo-b:
#   ./monitors/install-contabo-deadman.sh
#
# What it does (idempotent):
#   1. Verifies ssh (BatchMode) reaches the Contabo hosts and msmtp/sendmail
#      exists for the mail path. SMTP credentials are NEVER written here:
#      create ~/.msmtprc (0600) privately from the SES credentials in
#      ~/.secrets (see step notes below) BEFORE relying on paging.
#   2. Installs the every-5-min user-cron entry (never duplicates it).
#   3. Runs once normally (expect ALL_OK or a real finding, never a drill).
#
# Private msmtp setup (do this by hand, values stay in ~/.secrets):
#   - Build ~/.msmtprc (chmod 600) with your SES SMTP host/port/user/pass and
#     `from noreply@datatalks.club`, account default.
#   - Test: `echo -e "Subject: deadman msmtp test\n\nok" | msmtp -a default -- dev@dtcdev.click`
#     (one test mail on the authorized alert path), then delete the test line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/contabo-deadman.sh"
FAIL=0

echo "== syntax =="
bash -n "$SCRIPT" && echo SYNTAX_OK

echo "== ssh reachability (BatchMode) =="
for h in contabo-a contabo-b; do
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" 'echo ok' 2>/dev/null | grep -q ok; then
    echo "ssh $h: OK"
  else
    echo "ssh $h: FAIL (fix ~/.ssh/config + keys before relying on dead-man)"
    FAIL=1
  fi
done

echo "== mail path =="
if command -v sendmail >/dev/null 2>&1; then
  echo "sendmail present"
elif command -v msmtp >/dev/null 2>&1; then
  echo "msmtp present"
  if [[ -f "$HOME/.msmtprc" ]]; then
    echo "~/.msmtprc present ($(stat -c%a "$HOME/.msmtprc"))"
  else
    echo "WARN: ~/.msmtprc MISSING — create it privately (see header notes); alerts will be LOG-ONLY until then"
  fi
else
  echo "WARN: no MTA — install msmtp (sudo apt-get install msmtp-mta), then create ~/.msmtprc privately"
  FAIL=1
fi

echo "== user cron (every 5 min) =="
CRON_LINE="*/5 * * * * $SCRIPT >> $HOME/.local/state/contabo-deadman/cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$SCRIPT"; then
  echo "cron already installed"
else
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "cron installed: $CRON_LINE"
fi

echo "== first run (live, no drill) =="
mkdir -p "$HOME/.local/state/contabo-deadman"
bash "$SCRIPT" || echo "(exit $?: investigate real findings above — do NOT mask with FORCE_FAIL)"

if [[ "$FAIL" -ne 0 ]]; then
  echo "NEXT: fix ssh/msmtp WARNs above, then re-run this installer."
  exit 1
fi
echo Installed. Drill later with: DEADMAN_FORCE_FAIL=1 $SCRIPT
