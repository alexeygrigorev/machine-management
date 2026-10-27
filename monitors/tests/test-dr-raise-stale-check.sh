#!/usr/bin/env bash
# Exercise sparse weekly samples, failure paths, dry-run isolation, dedupe,
# the msmtp→sendmail→Relay transport chain and total-failure visibility.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# A sparse success exists in storage but is absent from instant lookback.
if [[ " $* " != *'query=time() - max(max_over_time(dr_fast_pg_raise_last_success_unixtime[691200s]))'* ]]; then
  echo '{"status":"success","data":{"result":[]}}'
  exit 0
fi
case "$FIXTURE" in
  missing) echo '{"status":"success","data":{"result":[]}}';;
  unreadable) echo 'unreadable';;
  *) printf '{"status":"success","data":{"result":[{"value":[0,"%s"]}]}}\n' "$FIXTURE";;
esac
STUB
cat > "$TMP/bin/msmtp" <<'STUB'
#!/usr/bin/env bash
echo "MSMTP_ARGS: $*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit "${MSMTP_RC:-0}"
STUB
cat > "$TMP/bin/sendmail" <<'STUB'
#!/usr/bin/env bash
echo "SENDMAIL_ARGS: $*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit "${SENDMAIL_RC:-0}"
STUB
cat > "$TMP/bin/datamailer" <<'STUB'
#!/usr/bin/env bash
echo "DATAMAILER_ARGS: $*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit "${DATAMAILER_RC:-0}"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" MAIL_LOG="$TMP/mail.log" DATAMAILER_BIN="$TMP/bin/datamailer"
export DR_RAISE_STALE_ENV_FILE="$TMP/no-env" STATE_DIR="$TMP/state" STALE_SECONDS=691200
export MSMTP_RC=0 SENDMAIL_RC=0 DATAMAILER_RC=0
run() {
  local expected="$1"; shift
  local rc=0
  env "$@" bash "$REPO/monitors/dr-raise-stale-check.sh" > "$TMP/output" 2>&1 || rc=$?
  if [[ "$rc" != "$expected" ]]; then
    cat "$TMP/output"
    echo "expected exit $expected, got $rc" >&2
    exit 1
  fi
}
bash -n "$REPO/monitors/dr-raise-stale-check.sh"
printf 'STATUS=FAIL\nLAST_ALERT=1\n' > "$STATE_DIR/stale.state"
cp "$STATE_DIR/stale.state" "$TMP/before"
for age in 45436 604799 648000 691200; do
  run 0 FIXTURE="$age" DRY_RUN=1
  rg -q 'OK last_success' "$TMP/output"
  cmp "$TMP/before" "$STATE_DIR/stale.state"
done
for fixture in missing unreadable 691201; do
  run 1 FIXTURE="$fixture" DRY_RUN=1
  rg -q 'DRY_RUN would alert' "$TMP/output"
  cmp "$TMP/before" "$STATE_DIR/stale.state"
done
run 0 FIXTURE=45436 DRY_RUN=1 STATE_DIR="$TMP/absent"
[[ ! -e "$TMP/absent" && ! -e "$MAIL_LOG" ]]
echo 'PASS: sparse samples fresh through 8d; missing/stale/unreadable fail; dry-run leaves mail/state untouched'
# A real failure alerts once via msmtp, dedupes the next run, and recovers once.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0
rg -q '^STATUS=FAIL$' "$STATE_DIR/stale.state"
rg -q 'via=msmtp' "$TMP/output"
rg -q '^MSMTP_ARGS: -a alerts -f alerts@dtcdev.click -- alexey@datatalks.club dev@dtcdev.click$' "$MAIL_LOG"
rg -q '^From: DTC Alerts <alerts@dtcdev.click>$' "$MAIL_LOG"
rg -q '^To: alexey@datatalks.club, dev@dtcdev.click$' "$MAIL_LOG"
! rg -q 'DATAMAILER_ARGS' "$MAIL_LOG"
cp "$MAIL_LOG" "$TMP/first-mail"
run 1 FIXTURE=missing DRY_RUN=0
rg -q 'dedupe: still FAIL' "$TMP/output"
cmp "$MAIL_LOG" "$TMP/first-mail"
run 0 FIXTURE=45436 DRY_RUN=0
rg -q '^STATUS=OK$' "$STATE_DIR/stale.state"
[[ "$(rg -c '^MSMTP_ARGS:' "$MAIL_LOG")" == 2 ]]
rg -q 'Subject: \[dr-fast-pg-raise\] RECOVERED' "$MAIL_LOG"
cp "$MAIL_LOG" "$TMP/recovered-mail"
run 0 FIXTURE=45436 DRY_RUN=0
cmp "$MAIL_LOG" "$TMP/recovered-mail"
echo 'PASS: msmtp primary alerts once, dedupes, and recovers once'

# msmtp down -> sendmail takes over, same recipients and headers.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0 MSMTP_RC=1
rg -q 'via=sendmail' "$TMP/output"
rg -q 'WARN: msmtp delivery failed' "$TMP/output"
rg -q '^SENDMAIL_ARGS: -t -f alerts@dtcdev.click$' "$MAIL_LOG"
rg -q '^From: DTC Alerts <alerts@dtcdev.click>$' "$MAIL_LOG"
! rg -q 'DATAMAILER_ARGS' "$MAIL_LOG"
echo 'PASS: sendmail fallback when msmtp fails'

# msmtp and sendmail down -> Relay last resort with IP-literal URLs defanged.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0 MSMTP_RC=1 SENDMAIL_RC=1
rg -q 'via=relay-fallback' "$TMP/output"
rg -q -- '--from alerts --to alexey@datatalks.club' "$MAIL_LOG"
rg -q -- '--from alerts --to dev@dtcdev.click' "$MAIL_LOG"
! rg -q 'http://127\.0\.0\.1' "$MAIL_LOG"
rg -q '127\.0\.0\.1' "$MAIL_LOG"
echo 'PASS: Relay fallback fires sanitized when the MTA path is down'

# The stale-age body (vmui URL with path) is defanged too; real hostnames pass through.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=691201 DRY_RUN=0 MSMTP_RC=1 SENDMAIL_RC=1
rg -q 'via=relay-fallback' "$TMP/output"
! rg -q 'http://127\.0\.0\.1' "$MAIL_LOG"
rg -q '127\.0\.0\.1:8428/vmui' "$MAIL_LOG"
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0 MSMTP_RC=1 SENDMAIL_RC=1 VM_URL='https://example.com:8443'
rg -q 'via=relay-fallback' "$TMP/output"
rg -q 'https://example\.com:8443' "$MAIL_LOG"
echo 'PASS: Relay sanitizer defangs IP-literal URLs, keeps hostnames'

# Everything down -> non-zero exit, loud error, state untouched.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
printf 'STATUS=OK\nLAST_ALERT=0\n' > "$STATE_DIR/stale.state"
cp "$STATE_DIR/stale.state" "$TMP/before-fail"
run 1 FIXTURE=missing DRY_RUN=0 MSMTP_RC=1 SENDMAIL_RC=1 DATAMAILER_RC=1
rg -q 'ERROR: all alert transports failed' "$TMP/output"
rg -q 'ERROR: Relay alert delivery request failed' "$TMP/output"
cmp "$STATE_DIR/stale.state" "$TMP/before-fail"
echo 'PASS: total delivery failure is loud and keeps state for retry'

# Test sends use dev only and never read VictoriaMetrics or change live state.
rm -f "$MAIL_LOG"
rm -f "$STATE_DIR/stale.state"
bash "$REPO/monitors/dr-raise-stale-check.sh" --test-alert > "$TMP/output" 2>&1
rg -q 'via=msmtp' "$TMP/output"
[[ "$(rg -c '^MSMTP_ARGS:' "$MAIL_LOG")" == 1 ]]
rg -q -- '-- dev@dtcdev.click' "$MAIL_LOG"
! rg -q 'alexey@datatalks.club' "$MAIL_LOG"
[[ ! -e "$STATE_DIR/stale.state" ]]
echo 'PASS: test alert is dev-only via the real chain'

# A test alert with every transport down fails loudly and touches no state.
rm -f "$MAIL_LOG"
rm -f "$STATE_DIR/stale.state"
rc=0
MSMTP_RC=1 SENDMAIL_RC=1 DATAMAILER_RC=1 bash "$REPO/monitors/dr-raise-stale-check.sh" --test-alert > "$TMP/output" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
rg -q 'ERROR: TEST alert delivery failed on every transport' "$TMP/output"
[[ ! -e "$STATE_DIR/stale.state" ]]
echo 'PASS: test alert failure is loud with no state changes'
