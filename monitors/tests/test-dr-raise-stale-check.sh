#!/usr/bin/env bash
# Exercise sparse weekly samples, failure paths, dry-run isolation, dedupe,
# Relay-only delivery with WAF-safe bodies and visible/retryable failures.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# A sparse success exists in storage but is absent from instant lookback.
echo query >> "$CURL_LOG"
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
set -euo pipefail
[[ -z "${DATAMAILER_API_KEY:-}" && -z "${DATAMAILER_URL:-}" ]]
[[ "$DATAMAILER_CONFIG" == "$RELAY_MONITOR_CONFIG" ]]
echo "DATAMAILER_ARGS: $*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit "${DATAMAILER_RC:-0}"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" MAIL_LOG="$TMP/mail.log" DATAMAILER_BIN="$TMP/bin/datamailer"
export CURL_LOG="$TMP/curl.log" RELAY_MONITOR_CONFIG="$TMP/relay.toml"
export DIGEST_SCRIPT="$TMP/no-digest" DIGEST_STATE_DIR="$TMP/digest"
export ALERT_TO=ops@example.com,dev@dtcdev.click
export DATAMAILER_API_KEY=must-not-override-monitor-client DATAMAILER_URL=https://override.invalid.test
export DR_RAISE_STALE_ENV_FILE="$TMP/no-env" STATE_DIR="$TMP/state" STALE_SECONDS=691200
export MSMTP_RC=0 SENDMAIL_RC=0 DATAMAILER_RC=0
reject_match() {
  local rc=0
  rg "$@" || rc=$?
  if [[ "$rc" != 1 ]]; then
    echo "expected no match (rg exit=$rc)" >&2
    exit 1
  fi
}
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
# A real failure uses Relay even when both local MTAs are healthy.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0
rg -q '^STATUS=FAIL$' "$STATE_DIR/stale.state"
rg -q 'via=relay' "$TMP/output"
rg -q '^DATAMAILER_ARGS: send --from alerts --to ops@example.com --subject' "$MAIL_LOG"
rg -q '^DATAMAILER_ARGS: send --from alerts --to dev@dtcdev.click --subject' "$MAIL_LOG"
reject_match -q 'MSMTP_ARGS|SENDMAIL_ARGS' "$MAIL_LOG"
cp "$MAIL_LOG" "$TMP/first-mail"
run 1 FIXTURE=missing DRY_RUN=0
rg -q 'dedupe: still FAIL' "$TMP/output"
cmp "$MAIL_LOG" "$TMP/first-mail"
run 0 FIXTURE=45436 DRY_RUN=0
rg -q '^STATUS=OK$' "$STATE_DIR/stale.state"
[[ "$(rg -c '^DATAMAILER_ARGS:' "$MAIL_LOG")" == 4 ]]
rg -q -- '--to dev@dtcdev.click --subject \[dr-fast-pg-raise\] RECOVERED' "$MAIL_LOG"
rg -q -- '--to ops@example.com --subject \[dr-fast-pg-raise\] RECOVERED' "$MAIL_LOG"
cp "$MAIL_LOG" "$TMP/recovered-mail"
run 0 FIXTURE=45436 DRY_RUN=0
cmp "$MAIL_LOG" "$TMP/recovered-mail"
echo 'PASS: Relay preserves custom recipients, dedupes failure/recovery; never uses healthy MTAs'

# Both missing and stale-age bodies are sanitized before the primary request.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0
rg -q 'via=relay' "$TMP/output"
rg -q -- '--from alerts --to ops@example.com' "$MAIL_LOG"
rg -q -- '--from alerts --to dev@dtcdev.click' "$MAIL_LOG"
reject_match -q 'http://127\.0\.0\.1' "$MAIL_LOG"
rg -q '127\.0\.0\.1' "$MAIL_LOG"
echo 'PASS: missing-sample body reaches Relay with its IP URL defanged'

# The stale-age body (vmui URL with path) is defanged too; real hostnames pass through.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=691201 DRY_RUN=0
rg -q 'via=relay' "$TMP/output"
reject_match -q 'http://127\.0\.0\.1' "$MAIL_LOG"
rg -q '127\.0\.0\.1:8428/vmui' "$MAIL_LOG"
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0 VM_URL='https://example.com:8443'
rg -q 'via=relay' "$TMP/output"
rg -q 'https://example\.com:8443' "$MAIL_LOG"
echo 'PASS: Relay sanitizer defangs IP-literal URLs, keeps hostnames'

# An isolated-state manual invocation must never page personal recipients,
# irrespective of whether an MTA exists on this Relay-only installation.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0 ALERT_TO=alexey@datatalks.club,dev@dtcdev.click
[[ "$(rg -c '^DATAMAILER_ARGS:' "$MAIL_LOG")" == 1 ]]
rg -q -- '--to dev@dtcdev.click' "$MAIL_LOG"
reject_match -q -- '--to alexey@datatalks.club' "$MAIL_LOG"
echo 'PASS: isolated-state runs strip personal recipients independently of MTA availability'

for url in 'http://127.0.0.1:8428?probe=1' 'https://127.0.0.1#probe' 'http://[::1]:8428/vmui'; do
  rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
  run 1 FIXTURE=missing DRY_RUN=0 VM_URL="$url"
  reject_match -q 'https?://' "$MAIL_LOG"
  rg -q '127\.0\.0\.1|\[::1\]' "$MAIL_LOG"
done
echo 'PASS: IPv4 query/fragment and bracketed IPv6 URLs are defanged'

# Relay down -> no SMTP bypass, non-zero exit, loud error, state untouched.
rm -f "$MAIL_LOG" "$STATE_DIR/stale.state"
printf 'STATUS=OK\nLAST_ALERT=0\n' > "$STATE_DIR/stale.state"
cp "$STATE_DIR/stale.state" "$TMP/before-fail"
run 1 FIXTURE=missing DRY_RUN=0 DATAMAILER_RC=1
rg -q 'ERROR: Relay alert delivery failed; dedupe state unchanged' "$TMP/output"
rg -q 'ERROR: Relay alert delivery request failed' "$TMP/output"
cmp "$STATE_DIR/stale.state" "$TMP/before-fail"
reject_match -q 'MSMTP_ARGS|SENDMAIL_ARGS' "$MAIL_LOG"
echo 'PASS: Relay failure stays visible and retryable without a direct-SMTP bypass'

# Test sends use dev only and never read VictoriaMetrics or change live state.
rm -f "$MAIL_LOG"
rm -f "$STATE_DIR/stale.state"
cp "$CURL_LOG" "$TMP/queries-before-test"
bash "$REPO/monitors/dr-raise-stale-check.sh" --test-alert > "$TMP/output" 2>&1
rg -q 'via=relay' "$TMP/output"
[[ "$(rg -c '^DATAMAILER_ARGS:' "$MAIL_LOG")" == 1 ]]
rg -q -- '--from alerts --to dev@dtcdev.click' "$MAIL_LOG"
rg -q '127\.0\.0\.1:8428/vmui' "$MAIL_LOG"
reject_match -q 'http://127\.0\.0\.1|MSMTP_ARGS|SENDMAIL_ARGS' "$MAIL_LOG"
reject_match -q -- '--to alexey@datatalks.club' "$MAIL_LOG"
[[ ! -e "$STATE_DIR/stale.state" ]]
cmp "$CURL_LOG" "$TMP/queries-before-test"
echo 'PASS: test alert proves the sanitized Relay path dev-only, without queries/state changes'

# A test alert with every transport down fails loudly and touches no state.
rm -f "$MAIL_LOG"
rm -f "$STATE_DIR/stale.state"
rc=0
DATAMAILER_RC=1 bash "$REPO/monitors/dr-raise-stale-check.sh" --test-alert > "$TMP/output" 2>&1 || rc=$?
[[ "$rc" == 1 ]]
rg -q 'ERROR: TEST Relay alert delivery failed' "$TMP/output"
[[ ! -e "$STATE_DIR/stale.state" ]]
echo 'PASS: test alert failure is loud with no state changes'

# Deployment wiring (68147e6c): the check reads the VM that holds the series,
# and cron never runs a git checkout that can lag origin/main.
grep -q '^0 9 \* \* \* alexey /usr/local/sbin/dr-raise-stale-check.sh' "$REPO/monitors/dr-raise-stale-check.cron"
grep -q '^VM_URL=http://127.0.0.1:8428$' "$REPO/monitors/install-dr-raise-stale-check.sh"
grep -q ' alexey /usr/local/lib/dr-fast-pg-raise/contingency/weekly-fast-pg-raise.sh ' "$REPO/contingency/weekly-fast-pg-raise.cron"
grep -q ' alexey /usr/local/lib/dr-fast-pg-raise/contingency/mirror-dr-raise-metrics.sh ' "$REPO/contingency/dr-raise-metrics-mirror.cron"
reject_match -q '^[^#].*/git/' "$REPO/contingency/weekly-fast-pg-raise.cron" "$REPO/contingency/dr-raise-metrics-mirror.cron" "$REPO/monitors/dr-raise-stale-check.cron"
echo 'PASS: crons run stable copies against the VM that holds the DR series'
