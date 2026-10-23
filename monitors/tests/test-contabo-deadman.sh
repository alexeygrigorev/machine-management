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
#   STUB_DM_STALE=host      -> mtime NOW-9999 (stale log)
#   STUB_DM_MISSING=host    -> garbage instead of mtime (unreadable log)
host=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2;;
    -*) shift;;
    *) host="$1"; shift; break;;
  esac
done
if [[ "${STUB_DM_SSH_FAIL:-}" == "$host" ]]; then
  echo "ssh: connect to host $host port 22: Connection timed out" >&2
  exit 7
fi
now="$(date +%s)"
if [[ "${STUB_DM_STALE:-}" == "$host" ]]; then
  echo "$(( now - 9999 ))"; echo "2026-10-23T10:00:00Z ALL_OK"; exit 0
fi
if [[ "${STUB_DM_MISSING:-}" == "$host" ]]; then
  echo "stat: cannot statx ..."; echo ""; exit 0
fi
echo "$(( now - 60 ))"; echo "2026-10-23T11:30:04Z ALL_OK"; exit 0
EOF
cat > "$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: honors -o <file>, prints code. URL = last arg.
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -w|--connect-timeout|--max-time) shift 2;;
    -*) shift;;
    *) url="$1"; shift;;
  esac
done
case "$url" in
  *good*) printf '{ "STATUS": "OK" }' > "$out"; echo "200"; exit 0;;
  *wrong*) printf '<html>edge default backend</html>' > "$out"; echo "200"; exit 0;;
  *down*) echo "curl: (7) connect failed" >&2; echo ""; exit 7;;
  *) echo "stub curl: unknown url $url" >&2; exit 99;;
esac
EOF
chmod +x "$TMP/stubbin/ssh" "$TMP/stubbin/curl"
cat > "$TMP/stubbin/sendmail" <<'EOF'
#!/usr/bin/env bash
# Capture recipients from To: header for drill recipient assertions.
mkdir -p "$STUB_DM_MAILDIR"
msg="$(cat)"
to="$(printf '%s\n' "$msg" | awk -F': ' 'BEGIN{IGNORECASE=1} /^To:/{print $2; exit}')"
subj="$(printf '%s\n' "$msg" | awk -F': ' 'BEGIN{IGNORECASE=1} /^Subject:/{print $2; exit}')"
printf '%s\t%s\n' "$to" "$subj" >> "$STUB_DM_MAILDIR/sent.tsv"
exit 0
EOF
chmod +x "$TMP/stubbin/sendmail"

run_dm() { # $1=hosts $2=urls $3=state-dir $4=force-fail(0/1)
  CONTABO_DEADMAN_ENV_FILE="/nonexistent" \
  STATE_DIR="$3" \
  LOCK_FILE="$3.lock" \
  DEADMAN_HOSTS="$1" \
  DEADMAN_URLS="$2" \
  DEADMAN_FORCE_FAIL="$4" \
  ALERT_TO="alexey@datatalks.club,dev@dtcdev.click" \
  ALERT_OPS_TO="dev@dtcdev.click" \
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
  && grep -q $'dev@dtcdev.click\t.*drill-forced' "$mailf" \
  && ! grep -q 'alexey@datatalks.club' "$mailf" \
  && [[ "$out" == *'to=dev@dtcdev.click'* ]]; then
  pass "D7 drill recipients ops-only (no alexey@)"
else
  fail "D7 ops-only drill -- out=$out mail=$(cat "$mailf" 2>/dev/null || echo missing)"
fi
out=""; set +e; out="$(run_dm 'node-a' "$GOOD_URLS" "$SD7" 0)"; rc=$?; set -e
if [[ $rc -eq 0 && $(wc -l < "$mailf") -eq 2 ]] \
  && grep -q $'dev@dtcdev.click\t.*RECOVERED.*drill-forced' "$mailf" \
  && ! grep -q 'alexey@datatalks.club' "$mailf"; then
  pass "D7 recovery recipients also ops-only (no alexey@)"
else
  fail "D7 ops-only recovery -- $out"
fi

# D8: a real failure during a drill still pages ALERT_TO.
SD8="$(mktemp -d -p "$TMP")"
out=""; set +e; out="$(STUB_DM_SSH_FAIL=node-a run_dm 'node-a' "$GOOD_URLS" "$SD8" 1)"; rc=$?; set -e
if [[ $rc -ne 0 ]] \
  && grep -q $'alexey@datatalks.club, dev@dtcdev.click\t.*FAIL.*node-node-a' "$SD8/mail/sent.tsv" \
  && grep -q $'dev@dtcdev.click\t.*FAIL.*drill-forced' "$SD8/mail/sent.tsv"; then
  pass "D8 real node failure during drill keeps both real recipients"
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

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
