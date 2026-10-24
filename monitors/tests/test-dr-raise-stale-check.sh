#!/usr/bin/env bash
# Exercise sparse weekly samples, failure paths, dry-run isolation and dedupe.
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
cat > "$TMP/bin/datamailer" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" MAIL_LOG="$TMP/mail.log" DATAMAILER_BIN="$TMP/bin/datamailer"
export DR_RAISE_STALE_ENV_FILE="$TMP/no-env" STATE_DIR="$TMP/state" STALE_SECONDS=691200
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
# A real failure alerts once, dedupes the next run, and recovers once.
rm "$STATE_DIR/stale.state"
run 1 FIXTURE=missing DRY_RUN=0
rg -q '^STATUS=FAIL$' "$STATE_DIR/stale.state"
cp "$MAIL_LOG" "$TMP/first-mail"
run 1 FIXTURE=missing DRY_RUN=0
rg -q 'dedupe: still FAIL' "$TMP/output"
cmp "$MAIL_LOG" "$TMP/first-mail"
run 0 FIXTURE=45436 DRY_RUN=0
rg -q '^STATUS=OK$' "$STATE_DIR/stale.state"
[[ "$(rg -c '^ARGS:' "$MAIL_LOG")" == 4 ]]
rg -q -- '--from alerts --to alexey@datatalks.club' "$MAIL_LOG"
rg -q -- '--from alerts --to dev@dtcdev.click' "$MAIL_LOG"
rg -q 'ARGS: send --from alerts' "$MAIL_LOG"
rg -q -- '--subject .*RECOVERED' "$MAIL_LOG"
cp "$MAIL_LOG" "$TMP/recovered-mail"
run 0 FIXTURE=45436 DRY_RUN=0
cmp "$MAIL_LOG" "$TMP/recovered-mail"
echo 'PASS: alert dedupe and single recovery preserved'

# Test sends use dev only and never read VictoriaMetrics or change live state.
rm "$MAIL_LOG"
bash "$REPO/monitors/dr-raise-stale-check.sh" --test-alert
[[ "$(rg -c '^ARGS:' "$MAIL_LOG")" == 1 ]]
rg -q -- '--to dev@dtcdev.click' "$MAIL_LOG"
! rg -q 'alexey@datatalks.club' "$MAIL_LOG"
echo 'PASS: test alert is dev-only'
