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
if [[ "$url" == https://relay.test/* || "$url" == https://dev.relay.test/* ]]; then
  [[ "${STUB_RELAY:-good}" == fail ]] && { code=503; body='unavailable'; }
fi
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
    SKIP_PUBLIC_HTTP_CHECKS="$4" STUB_RELAY="${STUB_RELAY:-good}" \
    APP_URLS='aishl=https://aishl.test/ping loopback=http://127.0.0.1/health/ relay=https://relay.test/health/ relay_dev=https://dev.relay.test/health/' \
    CONTENT_CHECKS='aishl_home=https://aishl.test/::"status":"ok" relay_health=https://relay.test/health/::"status":"ok" wg=http://10.100.0.2/health/::"status":"ok"' \
    STUB_RESPONSE="$2" STUB_NOW="$3" STUB_MAIL="$dir/mail" STUB_CURL_LOG="$dir/curls" \
    PATH="${EXTRA_PATH:+$EXTRA_PATH:}$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" > "$dir/log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${STUB_RELAY:-good}" == fail ]]; then
    require test "$rc" -eq 1
  elif [[ "$4" == 1 || "$2" == good ]]; then
    require test "$rc" -eq 0
  else
    require test "$rc" -eq 1
  fi
}
mail_count() { grep -c '^RELAY_SUBJECT:' "$1/mail" || true; }

# Same public outage on both hosts: two distinct checks, one pager each.
run_check "$TMP/a" fail 1000000 1
require test "$(mail_count "$TMP/a")" -eq 0
require grep -q 'OK check=http-loopback' "$TMP/a/log"
require grep -q 'OK check=content-wg' "$TMP/a/log"
pass 'contabo-a skips public HTTP and content, retains loopback/WG checks'

# One incident = one FAIL mail: http-aishl + content-aishl_home are the same
# service, so the first page goes to both recipients once and the sibling is held.
run_check "$TMP/b" fail 1000000 0
require test "$(mail_count "$TMP/b")" -eq 2
require test "$(grep -c '^RELAY_SUBJECT: .* FAIL (http-aishl)$' "$TMP/b/mail")" -eq 2
require test "$(grep -c 'content-aishl_home' "$TMP/b/mail")" -eq 0
require test "$(grep -c '^RELAY_TO: alexey@example.invalid.test$' "$TMP/b/mail")" -eq 1
require test "$(grep -c '^RELAY_TO: dev@invalid.test$' "$TMP/b/mail")" -eq 1
require test "$(grep -c '^RELAY_FROM: alerts$' "$TMP/b/mail")" -eq 2
require grep -q 'HOLD check=content-aishl_home' "$TMP/b/log"
pass 'AISHL outage (http + content failing) pages immediately: ONE FAIL mail per recipient, sibling held'

run_check "$TMP/b" fail 1000300 0
require test "$(mail_count "$TMP/b")" -eq 2
pass 'repeated failures during the incident stay deduped'

# Green for under 5 min: no RECOVERED yet; a re-FAIL inside the window is the SAME incident.
run_check "$TMP/b" good 1000400 0
require test "$(mail_count "$TMP/b")" -eq 2
run_check "$TMP/b" fail 1000500 0
require test "$(mail_count "$TMP/b")" -eq 2
pass 'flap inside the 5-min green window: no RECOVERED, no new FAIL'

run_check "$TMP/b" good 1000600 0
run_check "$TMP/b" good 1000900 0
require test "$(mail_count "$TMP/b")" -eq 3
require test "$(grep -c '^RELAY_SUBJECT: .* RECOVERED (svc-aisl)$' "$TMP/b/mail")" -eq 1
require test "$(grep -c '^RELAY_TO: dev@invalid.test$' "$TMP/b/mail")" -eq 2
require test "$(grep -c '^RELAY_TO: alexey@example.invalid.test$' "$TMP/b/mail")" -eq 1
pass 'RECOVERED only after 5 min continuous green, exactly once, to dev@ only'
run_check "$TMP/b" good 1001200 0
require test "$(mail_count "$TMP/b")" -eq 3
pass 'continued green does not repeat recovery mail'

# Flapping right after RECOVERED (within 15 min): held until it persists 5 min, then ONE page.
run_check "$TMP/b" fail 1001300 0
require test "$(mail_count "$TMP/b")" -eq 3
run_check "$TMP/b" good 1001400 0
require test "$(mail_count "$TMP/b")" -eq 3
run_check "$TMP/b" fail 1001500 0
run_check "$TMP/b" fail 1001800 0
require test "$(mail_count "$TMP/b")" -eq 5
pass 'post-recovery flap within 15 min is held; a sustained re-failure pages once after 5 min'

run_check "$TMP/long" fail 1000000 0
run_check "$TMP/long" fail 1003600 0
require test "$(mail_count "$TMP/long")" -eq 4
run_check "$TMP/long" good 1003601 0
run_check "$TMP/long" good 1003901 0
require test "$(mail_count "$TMP/long")" -eq 5
require grep -q 'incident lasted 3901s' "$TMP/long/mail"
pass 'hourly repeat reminder during a long incident; single RECOVERED reports total duration'

run_check "$TMP/marker" wrong 1000000 0
require test "$(mail_count "$TMP/marker")" -eq 2
require grep -q '^RELAY_SUBJECT: .* FAIL (content-aishl_home)$' "$TMP/marker/mail"
pass 'AISHL content mismatch with HTTP 200 still pages immediately'

# relay prod: http-relay + content-relay_health = ONE incident; relay_dev never mails.
# Relay self-checks bypass Relay and use SES via msmtp (outage independence).
mkdir -p "$TMP/sesbin"
cat > "$TMP/sesbin/msmtp" <<'SES'
#!/usr/bin/env bash
subj="$(sed -n 's/^Subject: //p' | head -1)"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
for to in "$@"; do printf 'RELAY_SUBJECT: %s\nRELAY_TO: %s\n---\n' "$subj" "$to" >> "$STUB_MAIL"; done
SES
chmod +x "$TMP/sesbin/msmtp"
EXTRA_PATH="$TMP/sesbin" STUB_RELAY=fail run_check "$TMP/r2" good 1000000 0
require test "$(grep -c '^RELAY_SUBJECT: .* FAIL (http-relay)$' "$TMP/r2/mail")" -eq 2
require test "$(grep -c 'content-relay_health\|relay_dev' "$TMP/r2/mail")" -eq 0
require grep -q 'DEV-ALERT check=http-relay_dev level=FAIL' "$TMP/r2/log"
require grep -q 'HOLD check=content-relay_health' "$TMP/r2/log"
pass 'relay prod 503: one FAIL (2 recipients) across http+content; dev env logs only, no mail'

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
