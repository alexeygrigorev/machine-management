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
cat > /dev/null
exit "${STUB_MAIL_RC:-0}"
EOF
chmod +x "$TMP/stubbin/docker" "$TMP/stubbin/sendmail"
cp "$TMP/stubbin/sendmail" "$TMP/stubbin/msmtp"

run() { # $1=proxy_nets -> prints output, returns rc
  set +e
  STUB_PROXY_NETS="$1" STUB_WANT_NET="svcnet123" \
    COOLIFY_PROXY_NETWORKS_ENV_FILE=/nonexistent STATE_DIR="${PAGER_STATE:-$TMP/state}" LOCK_FILE="$TMP/lock" \
    RECOVER_NOTIFY_MIN_SEC="${TEST_RECOVER_MIN_SEC:-0}" ALERT_TO=dev@dtcdev.click ALERT_FROM=noreply@test ALERT_REPEAT_MIN=60 \
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
if grep -qr "alexey@" "$TMP/state"; then
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

# Reproduce the real main healthcheck prune, then prove isolated state survives
# it between FAIL and a suppressed repeat / RECOVERED. No main-check exemption.
mkdir -p "$TMP/main"
printf 'STATUS=FAIL\nLAST_ALERT=1\n' > "$TMP/main/proxy-networks.state"
prune_main() {
  STATE_DIR="$TMP/main" bash -c "$(sed -n '/^prune_stale_checks() {/,/^}/p' "$REPO/monitors/coolify-healthcheck.sh")
log() { echo \"\$*\"; }
prune_stale_checks"
}
prune_main > "$TMP/prune.out"
if [[ ! -e "$TMP/main/proxy-networks.state" ]] && grep -q 'PRUNE check=proxy-networks' "$TMP/prune.out"; then
  pass "P5 reproduces main check pruning the old shared state"
else
  fail "P5 prune reproduction"
fi
export PAGER_STATE="$TMP/main/proxy-networks"
set +e; out="$(run "coolify")"; set -e
prune_main > "$TMP/prune-isolated.out"
set +e; out="$(run "coolify")"; rc=$?; set -e
if [[ $rc -ne 0 && -f "$PAGER_STATE/proxy-networks.state" && "$out" != *"ALERT check="* ]]; then
  pass "P6 main prune preserves isolated FAIL state and repeat suppression"
else
  fail "P6 isolated dedupe -- $out"
fi
set +e; out="$(run "coolify svcnet123")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"RECOVERED"* ]]; then
  pass "P7 recovery survives intervening main prune"
else
  fail "P7 isolated recovery -- $out"
fi

# Working mail path must prefer msmtp and specify its allowed identity/account.
cat > "$TMP/stubbin/msmtp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MAIL_ARGS"
cat > "$MAIL_BODY"
exit "${STUB_MAIL_RC:-0}"
EOF
chmod +x "$TMP/stubbin/msmtp"
export MAIL_ARGS="$TMP/mail.args" MAIL_BODY="$TMP/mail.body"
export PAGER_STATE="$TMP/mail-state" STUB_MAIL_RC=1
set +e; out="$(run "coolify")"; set -e
if [[ ! -f "$PAGER_STATE/proxy-networks.state" && "$out" == *"via=no"* ]]; then
  pass "P8 rejected transport does not suppress the next attempt"
else
  fail "P8 rejected send state -- $out"
fi
export STUB_MAIL_RC=0
set +e; out="$(run "coolify")"; set -e
if [[ "$out" == *"via=msmtp"* ]] && grep -qx 'alerts' "$MAIL_ARGS" &&
   grep -qx 'noreply@test' "$MAIL_ARGS" && grep -qx 'dev@dtcdev.click' "$MAIL_ARGS" &&
   grep -q '^To: dev@dtcdev.click$' "$MAIL_BODY"; then
  pass "P9 retry uses msmtp with explicit account/envelope and dev-only recipient"
else
  fail "P9 msmtp arguments -- $out"
fi
export STUB_MAIL_RC=1
set +e; out="$(run "coolify svcnet123")"; set -e
if grep -q 'STATUS=FAIL' "$PAGER_STATE/proxy-networks.state"; then
  pass "P10 failed recovery retains FAIL for retry"
else
  fail "P10 recovery transport state -- $out"
fi
export STUB_MAIL_RC=0
set +e; out="$(run "coolify svcnet123")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *"RECOVERED"* ]]; then
  pass "P11 recovery retry delivered"
else
  fail "P11 recovery retry -- $out"
fi

export TEST_RECOVER_MIN_SEC=600 PAGER_STATE="$TMP/rapid-state"
set +e; out="$(run "coolify")"; set -e
set +e; out="$(run "coolify svcnet123")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" != *"ALERT check="* ]] && grep -q 'STATUS=OK' "$PAGER_STATE/proxy-networks.state"; then
  pass "P12 rapid recovery updates state silently, matching main check"
else
  fail "P12 short recovery -- $out"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
