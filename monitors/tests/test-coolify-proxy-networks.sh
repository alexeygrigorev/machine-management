#!/usr/bin/env bash
# Focused pager test: monitors/coolify-proxy-networks.sh alert rules.
#   - detached -> exit 1, FAIL state, dev@-only alert line
#   - repeat within ALERT_REPEAT_MIN -> still FAIL but NO second alert line
#   - reattached -> exit 0, RECOVERED mail path, state OK
# Stub docker/sendmail on PATH; no prod, no secrets.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MONITOR="$REPO/monitors/coolify-proxy-networks.sh"

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

bash -n "$MONITOR" || { fail "syntax"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin" "$TMP/state"
cat > "$TMP/stubbin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ps" ]]; then echo "coolify-proxy"; echo "web-dev-stub"; exit 0; fi
if [[ "${1:-}" == "inspect" ]]; then
  fmt=""; name=""; shift
  while [[ $# -gt 0 ]]; do case "$1" in --format|-f) fmt="$2"; shift 2;; *) name="$1"; shift;; esac; done
  if [[ "$name" == "coolify-proxy" && -z "$fmt" ]]; then
    python3 -c 'import json,os; nets=os.environ.get("STUB_PROXY_NETS","coolify").split(); print(json.dumps([{"NetworkSettings":{"Networks":{n:{} for n in nets}}}]))'
    exit 0
  fi
  case "$fmt" in
    *traefik.enable*) [[ "$name" == "web-dev-stub" ]] && { echo "true"; exit 0; }; echo "<no value>"; exit 0;;
    *traefik.docker.network*) [[ "$name" == "web-dev-stub" ]] && { echo "${STUB_WANT_NET:-svcnet123}"; exit 0; }; echo "coolify"; exit 0;;
    *) echo "<no value>"; exit 0;;
  esac
fi
if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then exit 0; fi
echo "stub: $*" >&2; exit 99
EOF
cat > "$TMP/stubbin/sendmail" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/stubbin/docker" "$TMP/stubbin/sendmail"

run() { # $1=proxy_nets -> prints output, returns rc
  set +e
  STUB_PROXY_NETS="$1" STUB_WANT_NET="svcnet123" \
    COOLIFY_PROXY_NETWORKS_ENV_FILE=/nonexistent STATE_DIR="$TMP/state" LOCK_FILE="$TMP/lock" \
    ALERT_TO=dev@dtcdev.click ALERT_FROM=noreply@test ALERT_REPEAT_MIN=60 \
    PATH="$TMP/stubbin:/usr/bin:/bin" bash "$MONITOR" 2>&1
}
out=""; rc=0
set +e; out="$(run "coolify")"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *"FAIL check=proxy-networks"* && "$out" == *"ALERT check=proxy-networks"* && "$out" == *"to=dev@dtcdev.click"* ]]; then
  pass "P1 detached FAILs with dev@-only alert"
else
  fail "P1 detached (rc=$rc) -- $out"
fi
# No Alexey address anywhere in output/state.
if grep -qr "alexey@" "$TMP/state" "$TMP" 2>/dev/null | grep -v Binary; then
  fail "P2 no-alexey leak"
else
  pass "P2 alert path is dev@ only"
fi
set +e; out="$(run "coolify")"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *"FAIL check=proxy-networks"* && "$out" != *"ALERT check=proxy-networks"* ]]; then
  pass "P3 repeat suppressed within 60 min (dedupe)"
else
  fail "P3 dedupe (rc=$rc) -- $out"
fi
set +e; out="$(run "coolify svcnet123")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"RECOVERED"* && "$out" == *"ALL_OK"* ]]; then
  pass "P4 reattach RECOVERED + ALL_OK"
else
  fail "P4 recover (rc=$rc) -- $out"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
