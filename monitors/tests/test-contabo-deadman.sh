#!/usr/bin/env bash
# Regression tests for monitors/contabo-deadman.sh (t1143u R14).
# Stub ssh/curl on PATH (no network, no Contabo needed).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/contabo-deadman.sh"
INSTALLER="$REPO/monitors/install-contabo-deadman.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# 8138f287 AC0b: the suite must never configure a real recipient, even under
# stubs -- all ALERT_TO/ALERT_OPS_TO/LATENCY_ALERT_TO are non-routable.
T_ALARM="stub-alarm@invalid.test"   # ALERT_TO
T_OPS="stub-ops@invalid.test"       # ALERT_OPS_TO
T_LAT="stub-latency@invalid.test"   # LATENCY_ALERT_TO

# ---- D0: syntax ----
if bash -n "$SCRIPT" && bash -n "$INSTALLER"; then pass "D0 bash -n (deadman + installer)"; else fail "D0 bash -n"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: target host = first non-flag arg (skips -o K V pairs);
# behavior via $STUB_DM_*.
#   STUB_DM_SSH_FAIL=host   -> rc=7, no output (unreachable)
#   STUB_DM_STALE=host      -> completed run NOW-9999
#   STUB_DM_MISSING=host    -> garbage instead of a completed run
host=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2;;
    -*) shift;;
    *) host="$1"; shift; break;;
  esac
done
if [[ -n "${STUB_DM_LOG:-}" ]]; then
  exec bash -c "$1"
fi
if [[ "${STUB_DM_HANG:-}" == "$host" ]]; then sleep 30; fi
if [[ "${STUB_DM_SSH_FAIL:-}" == "$host" ]]; then
  echo "ssh: connect to host $host port 22: Connection timed out" >&2
  exit 7
fi
if [[ "${STUB_DM_STALE:-}" == "$host" ]]; then
  echo "$(date -u -d '9999 seconds ago' '+%Y-%m-%dT%H:%M:%SZ') ALL_OK"; exit 0
fi
if [[ "${STUB_DM_MISSING:-}" == "$host" ]]; then
  echo "stat: cannot statx ..."; echo ""; exit 0
fi
echo "$(date -u -d '60 seconds ago' '+%Y-%m-%dT%H:%M:%SZ') ALL_OK"; exit 0
EOF
cat > "$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: honors -o <file>, prints "code ttfb total" (latency) or code.
# URL = last arg. -L flag ignored (redirect-follow is a no-op in stub).
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -w|--connect-timeout|--max-time) shift 2;;
    -L) shift;;
    -*) shift;;
    *) url="$1"; shift;;
  esac
done
case "$url" in
  *slow*) printf '{ "STATUS": "OK" }' > "$out"; echo "200 5.00 5.20"; exit 0;;
  *fast*) printf '{ "STATUS": "OK" }' > "$out"; echo "200 0.20 0.30"; exit 0;;
  *good*) printf '{ "STATUS": "OK" }' > "$out"; echo "200 0.20 0.30"; exit 0;;
  *large*) python3 -c 'print("x" * 200000 + "\\n{\"STATUS\":\"OK\"}\\n" + "x" * 200000)' > "$out"; echo "200 0.20 0.30"; exit 0;;
  *wrong*) printf '<html>edge default backend</html>' > "$out"; echo "200 0.20 0.30"; exit 0;;
  *dash*) printf 'all-ok' > "$out"; echo "200 0.20 0.30"; exit 0;;
  *down*) echo "curl: (7) connect failed" >&2; echo ""; exit 7;;
  *) echo "stub curl: unknown url $url" >&2; exit 99;;
esac
EOF
chmod +x "$TMP/stubbin/ssh" "$TMP/stubbin/curl"
cat > "$TMP/stubbin/sendmail" <<'EOF'
#!/usr/bin/env bash
# Capture recipients and From header for drill recipient assertions.
# Fail closed: without a writable capture dir the stub refuses to deliver.
mkdir -p "$STUB_DM_MAILDIR" || { echo "stub sendmail: no capture dir; refusing" >&2; exit 1; }
[[ -d "${STUB_DM_MAILDIR:-}" && -w "$STUB_DM_MAILDIR" ]] || { echo "stub sendmail: capture dir missing/unwritable; refusing" >&2; exit 1; }
msg="$(cat)"
from="$(printf '%s\n' "$msg" | awk -F': ' 'BEGIN{IGNORECASE=1} /^From:/{print $2; exit}')"
to="$(printf '%s\n' "$msg" | awk -F': ' 'BEGIN{IGNORECASE=1} /^To:/{print $2; exit}')"
subj="$(printf '%s\n' "$msg" | awk -F': ' 'BEGIN{IGNORECASE=1} /^Subject:/{print $2; exit}')"
printf '%s\t%s\t%s\t%s\n' "$from" "$to" "$subj" "$*" >> "$STUB_DM_MAILDIR/sent.tsv"
[[ "${STUB_DM_MAIL_FAIL:-0}" == 1 ]] && exit 75
exit 0
EOF
chmod +x "$TMP/stubbin/sendmail"
cp "$TMP/stubbin/sendmail" "$TMP/stubbin/msmtp"
# Fail closed (8138f287 AC0b): abort unless every send path is stubbed.
for s in ssh curl sendmail msmtp; do
  [[ -x "$TMP/stubbin/$s" ]] || { echo "ABORT: stub '$s' missing from stubbin" >&2; exit 1; }
done

run_dm() { # $1=hosts $2=urls $3=state-dir $4=force-fail(0/1)
  CONTABO_DEADMAN_ENV_FILE="/nonexistent" \
  STATE_DIR="$3" \
  LOCK_FILE="$3.lock" \
  DEADMAN_HOSTS="$1" \
  DEADMAN_URLS="$2" \
  DEADMAN_FORCE_FAIL="$4" \
  LATENCY_PROBES="" \
  LATENCY_PUSH_ENABLED=0 \
  ALERT_TO="$T_ALARM,$T_OPS" \
  ALERT_OPS_TO="$T_OPS" \
  STUB_DM_MAILDIR="$3/mail" \
  PATH="$TMP/stubbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}

GOOD_URLS='svc=https://example.test/good::"status":"ok"'

# D1: all green -> ALL_OK
SD1="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm 'node-a node-b' "$GOOD_URLS" "$SD1" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'ALL_OK'* && "$out" == *'OK check=node-node-a'* && "$out" == *'OK check=ext-svc'* ]]; then
  pass "D1 green nodes + marker ALL_OK"
else
  fail "D1 green (rc=$rc) -- $out"
fi

# D2: one node unreachable -> FAIL names the node, other still OK
out=""; set +e; out="$(STUB_DM_SSH_FAIL=node-b run_dm 'node-a node-b' "$GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=node-node-b'* && "$out" == *'OK check=node-node-a'* ]]; then
  pass "D2 unreachable node FAILs by name, peer still OK"
else
  fail "D2 ssh fail (rc=$rc) -- $out"
fi

# D3: stale on-node log -> FAIL stale (cron may be dead)
out=""; set +e; out="$(STUB_DM_STALE=node-a run_dm 'node-a' "$GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=node-node-a'* && "$out" == *'stale'* ]]; then
  pass "D3 stale remote log FAILs"
else
  fail "D3 stale log (rc=$rc) -- $out"
fi

# D4: marker absent on 200 -> FAIL ext (wrong-content from outside)
out=""; set +e; out="$(run_dm 'node-a' 'svc=https://example.test/wrong::"status":"ok"' "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL check=ext-svc'* && "$out" == *"marker"* ]]; then
  pass "D4 wrong-content 200 FAILs external marker"
else
  fail "D4 marker miss (rc=$rc) -- $out"
fi

# D5: forced drill FAILs, then green run sends RECOVERED (same state dir)
SD5="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm 'node-a' "$GOOD_URLS" "$SD5" 1)"; rc=$?; set -e
t5a=1; [[ $rc -ne 0 && "$out" == *'FAIL check=drill-forced'* ]] || t5a=0
out=""; set +e; out="$(run_dm 'node-a' "$GOOD_URLS" "$SD5" 0)"; rc=$?; set -e
if [[ $t5a -eq 1 && $rc -eq 0 && "$out" == *'RECOVERED'* ]]; then
  pass "D5 drill FAIL then RECOVERED on restore"
else
  fail "D5 drill/recovery -- $out"
fi

# D7: drill mail recipients are ops-only (ALERT_OPS_TO), never alexey@ (t1273u/t1274u)
SD7="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm 'node-a' "$GOOD_URLS" "$SD7" 1)"; rc=$?; set -e
mailf="$SD7/mail/sent.tsv"
if [[ $rc -ne 0 && -f "$mailf" ]] \
  && grep -q $'DTC Alerts <alerts@dtcdev.click>\t'"$T_OPS"$'\t.*drill-forced' "$mailf" \
  && grep -q '\-a alerts.*\-f alerts@dtcdev\.click' "$mailf" \
  && ! grep -q "$T_ALARM" "$mailf" \
  && [[ "$out" == *"to=$T_OPS"* ]]; then
  pass "D7 drill recipients ops-only (no ALERT_TO)"
else
  fail "D7 ops-only drill -- out=$out mail=$(cat "$mailf" 2>/dev/null || echo missing)"
fi
out=""; set +e; out="$(run_dm 'node-a' "$GOOD_URLS" "$SD7" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && $(wc -l < "$mailf") -eq 2 ]] \
  && grep -q $'DTC Alerts <alerts@dtcdev.click>\t'"$T_OPS"$'\t.*RECOVERED.*drill-forced' "$mailf" \
  && ! grep -q "$T_ALARM" "$mailf"; then
  pass "D7 recovery recipients also ops-only (no ALERT_TO)"
else
  fail "D7 ops-only recovery -- $out"
fi

# D8: a real failure during a drill still pages ALERT_TO.
SD8="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(STUB_DM_SSH_FAIL=node-a run_dm 'node-a' "$GOOD_URLS" "$SD8" 1)"; rc=$?; set -e
if [[ $rc -ne 0 ]] \
  && grep 'FAIL.*node-node-a' "$SD8/mail/sent.tsv" | grep -q "$T_ALARM" \
  && grep 'FAIL.*node-node-a' "$SD8/mail/sent.tsv" | grep -q "$T_OPS" \
  && grep 'FAIL.*drill-forced' "$SD8/mail/sent.tsv" | grep -q "$T_OPS"; then
  pass "D8 real node failure during drill keeps both configured recipients"
else
  fail "D8 real failure recipients -- $out"
fi

# D6: malformed DEADMAN_URLS entry skipped, good entry still runs
out=""; set +e; out="$(run_dm 'node-a' "bogus $GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'skipping malformed DEADMAN_URLS entry'* && "$out" == *'OK check=ext-svc'* ]]; then
  pass "D6 malformed entry skipped, good probe green"
else
  fail "D6 malformed entry (rc=$rc) -- $out"
fi

# D8: recent skip/partial output must not refresh a hung monitor. Execute
# the actual remote reader against a fixture whose mtime is fresh.
fixture="$TMP/healthcheck.log"
printf '%s ALL_OK\n%s WARN: another healthcheck run is in progress; skipping\n' \
  "$(date -u -d '9999 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$fixture"
out=""; set +e
out="$(STUB_DM_LOG=1 DEADMAN_REMOTE_LOG="$fixture" run_dm 'node-a' "$GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"; rc=$?
set -e
if [[ $rc -ne 0 && "$out" == *'completed run age'* && "$out" == *'stale'* ]]; then
  pass "D8 fresh log mtime and lock-skip do not hide stale completed run"
else
  fail "D8 hung monitor freshness (rc=$rc) -- $out"
fi
printf '%s CHECKS_FAILED\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$fixture"
out="$(STUB_DM_LOG=1 DEADMAN_REMOTE_LOG="$fixture" run_dm 'node-a' "$GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"
if [[ "$out" == *ALL_OK* && "$out" == *CHECKS_FAILED* ]]; then
  pass "D9 completed failing check is fresh; on-node pager retains ownership"
else
  fail "D9 fresh CHECKS_FAILED -- $out"
fi

# D10: no completed record must fail even when the log is recently written.
printf '%s OK check=pg-shared\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$fixture"
out=""; set +e
out="$(STUB_DM_LOG=1 DEADMAN_REMOTE_LOG="$fixture" run_dm 'node-a' "$GOOD_URLS" "$(mktemp -d -p "$TMP")" 0)"; rc=$?
set -e
if [[ $rc -ne 0 && "$out" == *'completed run missing/unreadable'* ]]; then
  pass "D10 partial run without completion fails freshness"
else
  fail "D10 missing completion (rc=$rc) -- $out"
fi

SD11="$(mktemp -d -p "$TMP")"
out=""; set +e
out="$(STUB_DM_HANG=node-a DEADMAN_SSH_TIMEOUT=1 run_dm 'node-a node-b' "$GOOD_URLS" "$SD11" 0)"; rc=$?
set -e
if [[ $rc -ne 0 && "$out" == *'rc=124'* && "$out" == *'OK check=node-node-b'* ]]; then
  pass "D11 hung SSH times out and peer checks continue"
else
  fail "D11 SSH deadline (rc=$rc) -- $out"
fi

# D12: failure delivery is retried next run; a successful send then dedupes.
SD12="$(mktemp -d -p "$TMP")"
set +e
out="$(STUB_DM_MAIL_FAIL=1 run_dm 'node-a' "$GOOD_URLS" "$SD12" 1)"; rc=$?
set -e
[[ $rc -ne 0 && ! -f "$SD12/drill-forced.state" ]] || fail "D12 failed send must not advance state"
run_dm 'node-a' "$GOOD_URLS" "$SD12" 1 >/dev/null || true
run_dm 'node-a' "$GOOD_URLS" "$SD12" 1 >/dev/null || true
if [[ "$(wc -l < "$SD12/mail/sent.tsv")" -eq 2 ]] && grep -q '^STATUS=FAIL$' "$SD12/drill-forced.state"; then
  pass "D12 failed delivery retries immediately; accepted FAIL dedupes"
else
  fail "D12 delivery retry/dedupe"
fi
set +e
out="$(STUB_DM_MAIL_FAIL=1 run_dm 'node-a' "$GOOD_URLS" "$SD12" 0)"; rc=$?
set -e
if [[ $rc -ne 0 ]] && grep -q '^STATUS=FAIL$' "$SD12/drill-forced.state"; then
  run_dm 'node-a' "$GOOD_URLS" "$SD12" 0 >/dev/null
  grep -q '^STATUS=OK$' "$SD12/drill-forced.state"
  pass "D13 failed RECOVERED delivery retries before clearing FAIL state"
else
  fail "D13 recovery delivery retention (rc=$rc) -- $out"
fi

out="$(run_dm 'node-a' 'svc=https://example.test/large::"status":"ok"' "$(mktemp -d -p "$TMP")" 0)"
if [[ "$out" == *'OK check=ext-svc'* ]]; then
  pass "D14 large content marker match consumes pipe (no SIGPIPE false alarm)"
else
  fail "D14 large marker -- $out"
fi

# ---- D15-D16: latency probes (f5d8e22b: TTFB/total + dev-only slowness) ----
run_dm_lat() { # $1=latency_probes $2=sustain $3=state-dir
  CONTABO_DEADMAN_ENV_FILE="/nonexistent" \
  STATE_DIR="$3" \
  LOCK_FILE="$3.lock" \
  DEADMAN_HOSTS="node-a" \
  DEADMAN_URLS='svc=https://example.test/good::"status":"ok"' \
  DEADMAN_FORCE_FAIL=0 \
  LATENCY_PROBES="$1" LATENCY_SUSTAIN_SEC="$2" LATENCY_PUSH_ENABLED=0 \
  ALERT_TO="$T_ALARM,$T_OPS" \
  ALERT_OPS_TO="$T_OPS" LATENCY_ALERT_TO="$T_LAT" \
  STUB_DM_MAILDIR="$3/mail" \
  PATH="$TMP/stubbin:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}
# NOTE: stub curl maps *slow* -> 5s TTFB; *good/fast* -> 0.2s. See stubbin/curl.
SD15="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm_lat 'p1=https://example.test/fast::cmp' 0 "$SD15")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'latency probe=p1'* && "$out" == *'ttfb=0.20'* ]]; then
  pass "D15 fast latency records TTFB/total, no page"
else
  fail "D15 fast latency (rc=$rc) -- $out"
fi
SD16="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm_lat 'p1=https://example.test/slow::cmp' 0 "$SD16")"; rc=$?; set -e
if [[ $rc -ne 0 && "$out" == *'FAIL latency probe=p1'* ]]; then
  to_line="$(cat "$SD16/mail/sent.tsv" 2>/dev/null | tail -n 1 || true)"
  if [[ "$to_line" == *"$T_LAT"* && "$to_line" != *"$T_ALARM"* ]]; then
    pass "D16 slow latency FAILs LATENCY_ALERT_TO-only"
  else
    fail "D16 slow recipient not dev-only -- $to_line -- $out"
  fi
else
  fail "D16 slow latency (rc=$rc) -- $out"
fi

# ---- D17-D19: url::marker split on LAST '::' outside IPv6 brackets (8138f287) ----
# D17: IPv6 literal URL survives the split (old code probed 'http://[').
out=""; set +e; out="$(run_dm 'node-a' 'svc=http://[::1]/good::"status":"ok"' "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'OK check=ext-svc: http://[::1]/good -> 200'* && "$out" == *"marker='\"status\":\"ok\"'"* ]]; then
  pass "D17 IPv6 literal URL survives url::marker split"
else
  fail "D17 IPv6 split (rc=$rc) -- $out"
fi

# D18: IPv6 latency probe keeps url + service + bracketed url_host (old code
# fetched 'http://[' with service '1]/fast::cmp' and logged ttfb=-1).
SD18="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm_lat 'p1=http://[::1]/fast::cmp' 0 "$SD18")"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'latency probe=p1 service=cmp'* \
  && "$out" == *'url_host=[::1]'* && "$out" == *'ttfb=0.20'* ]]; then
  pass "D18 IPv6 latency probe splits on last '::' with sane url_host"
else
  fail "D18 IPv6 latency (rc=$rc) -- $out"
fi

# D19: dash-leading marker ('-ok', leaked FAIL mail #1) parses as the marker.
out=""; set +e; out="$(run_dm 'node-a' 'svc=https://example.test/dash::-ok' "$(mktemp -d -p "$TMP")" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && "$out" == *'https://example.test/dash -> 200'* && "$out" == *"marker='-ok'"* ]]; then
  pass "D19 dash-leading marker splits on last '::'"
else
  fail "D19 dash marker (rc=$rc) -- $out"
fi


# ---- D20: sentinel MTAs never fire; no real mail path reachable (AC0b, 8138f287) ----
SENT="$TMP/sentinel"; mkdir -p "$SENT"; : > "$SENT/invocations.log"
for s in msmtp sendmail aws; do
  cat > "$SENT/$s" <<EOF
#!/usr/bin/env bash
echo "$s \$*" >> "$SENT/invocations.log"
exit 99
EOF
  chmod +x "$SENT/$s"
done
run_dm_sent() { # $1=urls $2=force-fail $3=state-dir (PATH: stubs, then sentinels, then system)
  CONTABO_DEADMAN_ENV_FILE="/nonexistent" \
  STATE_DIR="$3" LOCK_FILE="$3.lock" DEADMAN_HOSTS="node-a" \
  DEADMAN_URLS="$1" DEADMAN_FORCE_FAIL="$2" \
  LATENCY_PROBES="" LATENCY_PUSH_ENABLED=0 \
  ALERT_TO="$T_ALARM,$T_OPS" \
  ALERT_OPS_TO="$T_OPS" \
  STUB_DM_MAILDIR="$3/mail" \
  PATH="$TMP/stubbin:$SENT:/usr/bin:/bin" \
  bash "$SCRIPT" 2>&1
}
SD20="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm_sent 'svc=https://example.test/good::"status":"ok"' 0 "$SD20")"; rc=$?; set -e
n_inv="$(wc -l < "$SENT/invocations.log")"
if [[ $rc -eq 0 && "$n_inv" -eq 0 && ! -s "$SD20/mail/sent.tsv" ]]; then
  pass "D20 sentinel MTAs silent, zero sends on green run"
else
  fail "D20 green (rc=$rc inv=$n_inv) -- $(cat "$SENT/invocations.log" 2>/dev/null)"
fi
SD20B="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(run_dm_sent 'svc=https://example.test/good::"status":"ok"' 1 "$SD20B")"; rc=$?; set -e
n_inv="$(wc -l < "$SENT/invocations.log")"
row20="$(tail -n 1 "$SD20B/mail/sent.tsv" 2>/dev/null || true)"
if [[ $rc -ne 0 && "$n_inv" -eq 0 && "$row20" == *"$T_OPS"* && "$row20" != *"$T_ALARM"* ]]; then
  pass "D20 sentinel MTAs silent on drill; send captured by stub only"
else
  fail "D20 drill (rc=$rc inv=$n_inv row=[$row20])"
fi

# ---- D21: suite-wide recipient sweep (9806fc14) — no real datatalks.club
# recipient may appear in ANY captured mail. The c0e34bb-era suite configured
# the real ALERT_TO and mailed alexey@ from its FAIL-path tests (2026-10-27);
# 6049ee8 closed that, this sweep keeps it closed. ----
if grep -rq 'datatalks\.club' "$TMP" 2>/dev/null; then
  fail "D21 real datatalks.club recipient leaked into captured mail/stubs"
else
  pass "D21 no real datatalks.club recipient anywhere in captured mail"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
