#!/usr/bin/env bash
# t1228u: transient curl rc 28 (DNS resolve timeout) must retry; persistent still FAILs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/coolify-healthcheck.sh"
PASS=0; FAILN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAILN=$((FAILN+1)); echo "FAIL: $1"; }
bash -n "$SCRIPT" && pass "bash -n" || fail "bash -n"
grep -qF 'HTTP_RETRIES="${HTTP_RETRIES:-2}"' "$SCRIPT" && pass "HTTP_RETRIES default" || fail "HTTP_RETRIES default"
grep -qF 'HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-10}"' "$SCRIPT" && pass "CONNECT_TIMEOUT default" || fail "CONNECT_TIMEOUT default"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/curl" <<'C'
#!/usr/bin/env bash
STATE_DIR="${CURL_STUB_STATE}"; mkdir -p "$STATE_DIR"
url=""; while [[ $# -gt 0 ]]; do
  case "$1" in -o|-w|--connect-timeout|--max-time) shift 2;; -sS|-fsS|-f|-s|-S) shift;; -*) shift;; *) url="$1"; shift;; esac
done
f="$STATE_DIR/$(printf %s "$url" | tr -c A-Za-z0-9 _).n"
n=0; [[ -f $f ]] && n=$(cat "$f"); n=$((n+1)); echo "$n" >"$f"
if [[ $n -eq 1 ]]; then echo "curl: (28) Resolving timed out after 5001 milliseconds" >&2; printf 000; exit 28; fi
printf 200; exit 0
C
chmod +x "$TMP/stubbin/curl"
cat > "$TMP/stubbin/docker" <<'D'
#!/usr/bin/env bash
exit 0
D
chmod +x "$TMP/stubbin/docker"
export CURL_STUB_STATE="$TMP/cs"
rm -rf "$CURL_STUB_STATE"
set +e
OUT="$(
  PATH="$TMP/stubbin:$PATH" COOLIFY_HEALTHCHECK_ENV_FILE=/dev/null \
  STATE_DIR="$TMP/s1" LOCK_FILE="$TMP/l1" LOG_FILE="$TMP/log1" \
  SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_DISK_CHECK=1 SKIP_BACKUP_CHECKS=1 CHECK_CMP_CALLBACKS=0 \
  APP_URLS="relay=https://relay.example.test/health/" CONTENT_CHECKS= \
  HTTP_RETRIES=2 HTTP_RETRY_SLEEP_SEC=0 HTTP_CONNECT_TIMEOUT=5 HTTP_TIMEOUT=5 ALERT_TO= \
  bash "$SCRIPT" 2>&1
)"; RC=$?; set -e
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q 'OK check=http-relay: .* -> 200' && echo "$OUT" | grep -q 'http-retry'; then
  pass "retry then OK"
else fail "retry then OK rc=$RC $(echo "$OUT"|tr '\n' '|')"
fi
cat > "$TMP/stubbin/curl" <<'C'
#!/usr/bin/env bash
echo "curl: (28) Resolving timed out after 5001 milliseconds" >&2; printf 000; exit 28
C
chmod +x "$TMP/stubbin/curl"
cat > "$TMP/stubbin/docker" <<'D'
#!/usr/bin/env bash
exit 0
D
chmod +x "$TMP/stubbin/docker"
set +e
OUT2="$(
  PATH="$TMP/stubbin:$PATH" COOLIFY_HEALTHCHECK_ENV_FILE=/dev/null \
  STATE_DIR="$TMP/s2" LOCK_FILE="$TMP/l2" LOG_FILE="$TMP/log2" \
  SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_DISK_CHECK=1 SKIP_BACKUP_CHECKS=1 CHECK_CMP_CALLBACKS=0 \
  APP_URLS="relay=https://relay.example.test/health/" CONTENT_CHECKS= \
  HTTP_RETRIES=1 HTTP_RETRY_SLEEP_SEC=0 HTTP_CONNECT_TIMEOUT=5 HTTP_TIMEOUT=5 ALERT_TO= \
  bash "$SCRIPT" 2>&1
)"; RC2=$?; set -e
if [[ $RC2 -ne 0 ]] && echo "$OUT2" | grep -q 'FAIL check=http-relay'; then pass "exhaust still FAIL"
else fail "exhaust rc=$RC2"
fi
echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
