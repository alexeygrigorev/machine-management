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
#   2. Installs the every-minute dead-man and daily 503 digest user-cron entries.
#   3. Runs once normally (expect ALL_OK or a real finding, never a drill).
#
# Private msmtp setup (do this by hand, values stay in ~/.secrets):
#   - Build ~/.msmtprc (chmod 600) with your SES SMTP host/port/user/pass and
#     `from alerts@dtcdev.click`, account alerts.
#   - Test: `echo -e "Subject: deadman msmtp test\n\nok" | msmtp -a alerts -- dev@dtcdev.click`
#     (one test mail on the authorized alert path), then delete the test line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/contabo-deadman.sh"
# Stable runtime path (worktrees come and go; the pager must not die with one).
SCRIPT="/usr/local/sbin/contabo-deadman.sh"
DIGEST_SCRIPT="/usr/local/sbin/contabo-503-digest.sh"
FAIL=0

echo "== install script to stable path =="
for path in "$SCRIPT" "$DIGEST_SCRIPT" /usr/local/sbin/contabo-503-digest.py /usr/local/sbin/ops-daily-digest.sh; do
  if sudo test -e "$path" && ! sudo test -e "${path}.pre-alerts-from"; then
    sudo cp -a "$path" "${path}.pre-alerts-from"
  fi
done
sudo install -m 0755 "$SCRIPT_SRC" "$SCRIPT"
sudo install -m 0755 "$HERE/contabo-503-digest.sh" /usr/local/sbin/contabo-503-digest.sh
sudo install -m 0644 "$HERE/contabo-503-digest.py" /usr/local/sbin/contabo-503-digest.py
sudo install -m 0755 "$HERE/ops-daily-digest.sh" /usr/local/sbin/ops-daily-digest.sh
sudo install -m 0644 "$HERE/relay-alert-lib.sh" /usr/local/sbin/relay-alert-lib.sh
sudo install -m 0644 "$HERE/incident-gate.sh" /usr/local/sbin/incident-gate.sh
bash -n "$SCRIPT" && bash -n "$DIGEST_SCRIPT" \
  && python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' /usr/local/sbin/contabo-503-digest.py \
  && echo SYNTAX_OK

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
if [[ -x "${DATAMAILER_BIN:-$HOME/.local/bin/datamailer}" ]]; then
  echo "datamailer present (used by Relay-routed daily digest)"
else
  echo "WARN: datamailer missing — the daily ops digest cannot be sent through Relay"
  FAIL=1
fi

echo "== user cron (minute public probe + daily 503 digest) =="
CRON_LINE="* * * * * $SCRIPT >> $HOME/.local/state/contabo-deadman/cron.log 2>&1"
DIGEST_LINE="5 8 * * * /usr/local/sbin/contabo-503-digest.sh >> $HOME/.local/state/contabo-deadman/503-digest.log 2>&1"
EXISTING_CRON="$(crontab -l 2>/dev/null || true)"
install_cron_line() {
  local key="$1" line="$2" stable_path="$3"
  if grep -F "$key" <<<"$EXISTING_CRON" | grep -Fv "$line" | grep -q . \
    && grep -F "$key" <<<"$EXISTING_CRON" | grep -Fv "$stable_path" | grep -q .; then
    echo "WARN: an existing $key cron uses a different command; inspect crontab before continuing"
    grep -F "$key" <<<"$EXISTING_CRON"
    FAIL=1
    return
  fi
  if grep -qF "$line" <<<"$EXISTING_CRON"; then
    echo "cron already installed: $key"
    return
  fi
  if grep -qF "$key" <<<"$EXISTING_CRON"; then
    EXISTING_CRON="$(grep -Fv "$key" <<<"$EXISTING_CRON" || true)"
  fi
  EXISTING_CRON="$(printf '%s\n%s' "$EXISTING_CRON" "$line")"
  printf '%s\n' "$EXISTING_CRON" | crontab -
  echo "cron installed: $key"
}
install_cron_line "contabo-deadman.sh" "$CRON_LINE" "$SCRIPT"
install_cron_line "contabo-503-digest.sh" "$DIGEST_LINE" "$DIGEST_SCRIPT"

echo "== first run (live, no drill) =="
mkdir -p "$HOME/.local/state/contabo-deadman"
bash "$SCRIPT" || echo "(exit $?: investigate real findings above — do NOT mask with FORCE_FAIL)"
echo "== direct F4 short-503 digest query (dry-run) =="
bash "$DIGEST_SCRIPT" --dry-run

if [[ "$FAIL" -ne 0 ]]; then
  echo "NEXT: fix ssh/msmtp WARNs above, then re-run this installer."
  exit 1
fi
echo Installed. Public 2xx/3xx probes page after 120 seconds of continuous failure.
echo Daily short 5xx metrics digest runs at 08:05 Europe/Berlin and uses direct mail.
echo Drill later with: DEADMAN_FORCE_FAIL=1 $SCRIPT
echo "Drill FAIL and RECOVERED use ALERT_OPS_TO (default dev@dtcdev.click) only."
echo "Keep ALERT_TO=dev@dtcdev.click for real failures."
