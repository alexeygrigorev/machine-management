#!/usr/bin/env bash
# curl rc 35/56 (TLS/recv reset): exactly one retry, then OK; persistent still FAILs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/../.." && pwd)/monitors/coolify-healthcheck.sh"
PASS=0; FAILN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAILN=$((FAILN+1)); echo "FAIL: $1"; }
grep -qF "RECOVER_NOTIFY_MIN_SEC" "$SCRIPT" && grep -qE "RECOVER_NOTIFY_MIN_SEC:-600" "$SCRIPT" && pass "recover 600 kept" || fail "recover 600"
TMP="$(mktemp -d)"; trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"; export TEST_MAIL="$TMP/mail"
printf "#!/usr/bin/env bash\ncat >> \"\$TEST_MAIL\"\n" > "$TMP/bin/msmtp"
printf "#!/usr/bin/env bash\nexit 0\n" > "$TMP/bin/docker"
cat > "$TMP/bin/curl" <<"C"
#!/usr/bin/env bash
w=""; prev=""; for a in "$@"; do [[ $prev == -w ]] && w="$a"; prev="$a"; done
last="${@: -1}"
if [[ $w != "%{http_code}" || $last != *127.0.0.9* ]]; then printf "200 0.01 0.01"; exit 0; fi
f="$CURL_STUB_STATE/n"; n=0; [[ -f $f ]] && n=$(cat "$f"); n=$((n+1)); echo "$n" >"$f"
if [[ $n -le $CURL_FAILS ]]; then echo "curl: ($CURL_RC) Recv failure: Connection reset by peer" >&2; printf 000; exit "$CURL_RC"; fi
printf 200; exit 0
C
chmod +x "$TMP/bin/"*
run(){ # $1=rc $2=fails $3=tag $4=mode(http|content)
  mkdir -p "$TMP/cs$3"; local apps="relay=https://127.0.0.9/health/" cc=""
  if [[ $4 == content ]]; then apps=""; apps="relay=https://127.0.0.1/health/"; cc="relay=https://127.0.0.9/::x"; fi
  set +e
  OUT="$(PATH="$TMP/bin:$PATH" CURL_STUB_STATE="$TMP/cs$3" CURL_RC=$1 CURL_FAILS=$2 COOLIFY_HEALTHCHECK_ENV_FILE=/dev/null \
    STATE_DIR="$TMP/s$3" LOCK_FILE="$TMP/l$3" LOG_FILE="$TMP/log$3" \
    SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_DISK_CHECK=1 SKIP_BACKUP_CHECKS=1 CHECK_CMP_CALLBACKS=0 \
    APP_URLS="$apps" CONTENT_CHECKS="$cc" HTTP_RETRIES=2 HTTP_RETRY_SLEEP_SEC=0 HTTP_RESET_RETRY_SLEEP_SEC=0 \
    ALERT_TO=retry-test@example.test bash "$SCRIPT" 2>&1)"; RC=$?; set -e
  CALLS=$(cat "$TMP/cs$3/n" 2>/dev/null || echo 0)
}
for code in 35 56; do
  run $code 1 a$code http
  [[ $RC -eq 0 && $CALLS -eq 2 ]] && echo "$OUT" | grep -q "OK check=http-relay" && pass "http rc$code retried once then OK" || fail "http rc$code once rc=$RC calls=$CALLS"
  run $code 9 b$code http
  [[ $RC -ne 0 && $CALLS -eq 2 ]] && echo "$OUT" | grep -q "FAIL check=http-relay" && pass "http rc$code persistent FAIL after 1 retry" || fail "http rc$code persistent rc=$RC calls=$CALLS"
  run $code 1 c$code content
  echo "$OUT" | grep -q "content-retry" && ! echo "$OUT" | grep -q "FAIL check=content-relay: curl" && [[ $CALLS -eq 2 ]] && pass "content rc$code retried once" || fail "content rc$code calls=$CALLS"
done
[[ -f "$TEST_MAIL" ]] && ! grep -qE "alexey@datatalks.club|dev@dtcdev.click" "$TEST_MAIL" && pass "mail isolated" || fail "mail isolation"
echo "---- $PASS passed, $FAILN failed ----"; [[ $FAILN -eq 0 ]]
