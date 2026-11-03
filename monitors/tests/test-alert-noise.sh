#!/usr/bin/env bash
# Alert routing and outage timing regression tests (t1273u/t1274u).
# Real script, stubbed clock/network/mail; no external services or mail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../coolify-healthcheck.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
PASS=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
require() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
# No PG or Created containers in this fixture.
exit 0
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '+%s' ]]; then echo "$STUB_NOW"; else /bin/date "$@"; fi
EOF
cat > "$TMP/bin/datamailer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
from=""; to=""; subject=""; prev=""
for arg in "$@"; do
  case "$prev" in --from) from="$arg";; --to) to="$arg";; --subject) subject="$arg";; esac
  prev="$arg"
done
printf 'RELAY_FROM: %s\nRELAY_TO: %s\nRELAY_SUBJECT: %s\n' "$from" "$to" "$subject" >> "$STUB_MAIL"
cat >> "$STUB_MAIL"
printf '\n---\n' >> "$STUB_MAIL"
EOF
cat > "$TMP/bin/msmtp" <<'EOF'
#!/usr/bin/env bash
echo 'unexpected direct SMTP path' >&2
exit 99
EOF
cp "$TMP/bin/msmtp" "$TMP/bin/sendmail"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''; url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -w|--connect-timeout|--max-time) shift 2;;
    -*) shift;;
    *) url="$1"; shift;;
  esac
done
echo "$url" >> "$STUB_CURL_LOG"
code=200; body='{"status":"ok"}'
if [[ "$url" == https://aishl.test/* ]]; then
  case "$STUB_RESPONSE" in
    fail) code=503; body='unavailable';;
    wrong) body='proxy default page';;
  esac
fi
if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; fi
printf '%s' "$code"
EOF
chmod +x "$TMP/bin/"*
export DATAMAILER_BIN="$TMP/bin/datamailer"
export RELAY_MONITOR_CONFIG="$TMP/relay.toml"

run_check() { # state-dir, response, epoch, skip-public
  local dir="$1" rc
  mkdir -p "$dir"
  touch "$dir/mail" "$dir/curls"
  if COOLIFY_HEALTHCHECK_ENV_FILE=/nonexistent \
    STATE_DIR="$dir" LOCK_FILE="$dir/lock" \
    SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_BACKUP_CHECKS=1 SKIP_DISK_CHECK=1 \
    CHECK_AISL_Q=0 CHECK_CMP_CALLBACKS=0 LATENCY_PROBES= LATENCY_PUSH_ENABLED=0 \
    ALERT_TO=alexey@example.invalid.test,dev@invalid.test ALERT_REPEAT_MIN=60 \
    RECOVER_NOTIFY_MIN_SEC=600 SKIP_PUBLIC_HTTP_CHECKS="$4" \
    APP_URLS='aishl=https://aishl.test/ping loopback=http://127.0.0.1/health/' \
    CONTENT_CHECKS='aishl_home=https://aishl.test/::"status":"ok" wg=http://10.100.0.2/health/::"status":"ok"' \
    STUB_RESPONSE="$2" STUB_NOW="$3" STUB_MAIL="$dir/mail" STUB_CURL_LOG="$dir/curls" \
    PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" > "$dir/log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$4" == 1 || "$2" == good ]]; then
    require test "$rc" -eq 0
  else
    require test "$rc" -eq 1
  fi
}
mail_count() { grep -c '^RELAY_SUBJECT:' "$1/mail" || true; }

# Same public outage on both hosts: two distinct checks, one pager each.
run_check "$TMP/a" fail 1000000 1
require test "$(mail_count "$TMP/a")" -eq 0
require test "$(wc -l < "$TMP/a/curls")" -eq 2
require grep -q 'OK check=http-loopback' "$TMP/a/log"
require grep -q 'OK check=content-wg' "$TMP/a/log"
pass 'contabo-a skips public HTTP and content, retains loopback/WG checks'

run_check "$TMP/b" fail 1000000 0
require test "$(mail_count "$TMP/b")" -eq 4
require test "$(grep -c '^RELAY_SUBJECT: .* FAIL (http-aishl)$' "$TMP/b/mail")" -eq 2
require test "$(grep -c '^RELAY_SUBJECT: .* FAIL (content-aishl_home)$' "$TMP/b/mail")" -eq 2
require test "$(grep -c '^RELAY_TO: alexey@example.invalid.test$' "$TMP/b/mail")" -eq 2
require test "$(grep -c '^RELAY_TO: dev@invalid.test$' "$TMP/b/mail")" -eq 2
require test "$(grep -c '^RELAY_FROM: alerts$' "$TMP/b/mail")" -eq 4
pass 'contabo-b immediately pages both recipients through Relay sender alerts for AISHL HTTP/content 503'

run_check "$TMP/b" fail 1000300 0
require test "$(mail_count "$TMP/b")" -eq 4
pass 'repeated public failures remain deduped'

run_check "$TMP/b" good 1000599 0
require test "$(mail_count "$TMP/b")" -eq 4
require grep -q '^STATUS=OK$' "$TMP/b/http-aishl.state"
require grep -q '^STATUS=OK$' "$TMP/b/content-aishl_home.state"
pass '599-second recovery resets state without RECOVERED mail'

run_check "$TMP/boundary" fail 1000000 0
run_check "$TMP/boundary" good 1000600 0
require test "$(mail_count "$TMP/boundary")" -eq 6
require test "$(grep -c '^RELAY_SUBJECT: .* RECOVERED' "$TMP/boundary/mail")" -eq 2
require test "$(grep -c '^RELAY_TO: dev@invalid.test$' "$TMP/boundary/mail")" -eq 4
require test "$(grep -c '^RELAY_TO: alexey@example.invalid.test$' "$TMP/boundary/mail")" -eq 2
pass '600-second boundary sends exactly one RECOVERED per check (to dev@ only, never alexey@)'
run_check "$TMP/boundary" good 1000900 0
require test "$(mail_count "$TMP/boundary")" -eq 6
pass 'continued green does not repeat recovery mail'

run_check "$TMP/long" fail 1000000 0
run_check "$TMP/long" fail 1003600 0
require test "$(mail_count "$TMP/long")" -eq 8
require grep -q '^FAIL_SINCE=1000000$' "$TMP/long/http-aishl.state"
run_check "$TMP/long" good 1003601 0
require test "$(mail_count "$TMP/long")" -eq 10
require grep -q 'was FAIL for 3601s' "$TMP/long/mail"
pass 'repeat alerts preserve outage start for recovery timing'

run_check "$TMP/marker" wrong 1000000 0
require test "$(mail_count "$TMP/marker")" -eq 2
require grep -q '^RELAY_SUBJECT: .* FAIL (content-aishl_home)$' "$TMP/marker/mail"
pass 'AISHL content mismatch with HTTP 200 still pages immediately'

# Stale check pruning (t1342u): checks no longer in config (e.g. content-relay_dtcdev)
# have their .state files pruned automatically.
mkdir -p "$TMP/prune"
touch "$TMP/prune/content-relay_dtcdev.state"
touch "$TMP/prune/http-staleapp.state"
run_check "$TMP/prune" good 1000000 0
require test ! -f "$TMP/prune/content-relay_dtcdev.state"
require test ! -f "$TMP/prune/http-staleapp.state"
require test -f "$TMP/prune/http-aishl.state"
require test -f "$TMP/prune/content-aishl_home.state"
pass 'stale state files for removed checks (content-relay_dtcdev, http-staleapp) pruned automatically'

echo "---- $PASS passed, 0 failed ----"
