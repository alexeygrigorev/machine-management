#!/usr/bin/env bash
# Regression tests for storagebox mirror fix (t1553u):
# - monitors/storagebox-staleness-check.sh (36h dead-man, DRY_RUN + drill)
# - backups/storagebox-sync.sh (no main-temp, writable log path)
# Runs the real scripts with stub msmtp on PATH (no root, no network, no mail).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/storagebox-staleness-check.sh"
SYNC="$REPO/backups/storagebox-sync.sh"
CRON="$REPO/backups/storagebox-sync.cron"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }
check_grep() {
  if grep -qF "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

# ---- T1: syntax ----
if bash -n "$SCRIPT" \
  && bash -n "$REPO/monitors/install-storagebox-staleness-check.sh" \
  && bash -n "$SYNC" \
  && bash -n "$REPO/backups/install-storagebox-sync.sh"; then
  pass "T1 bash -n (staleness check + installer + sync + sync installer)"
else
  fail "T1 bash -n"
fi

# ---- T2: safe defaults in repo ----
check_grep "$SCRIPT" 'ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"' "T2a prod recipients default"
check_grep "$SCRIPT" 'ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"' "T2b drill recipient dev-only"
check_grep "$SCRIPT" 'STALE_SECONDS="${STALE_SECONDS:-129600}"' "T2c 36h threshold default"
check_grep "$SCRIPT" 'DRY_RUN' "T2d DRY_RUN mode present"
check_grep "$SCRIPT" 'STORAGEBOX_STALE_DRILL' "T2e drill mode present"
check_grep "$SYNC" 'storagebox-mirror-reader' "T2f sync uses dedicated reader profile"
check_grep "$CRON" '.local/state/storagebox-sync/storagebox-backup-sync.log' "T2g cron log writable by alexey"
check_grep "$REPO/monitors/storagebox-staleness-check.cron" '/usr/local/sbin/storagebox-staleness-check.sh' "T2h staleness cron stable path"
if grep -q "main-temp" "$SYNC" && ! grep -q 'AWS_PROFILE.*main-temp.*forbidden' "$SYNC"; then
  fail "T2i sync must not default to main-temp"
else
  # Allow the word main-temp ONLY in the forbidden-guard + comments.
  if grep -q 'AWS_PROFILE:-main-temp' "$SYNC"; then
    fail "T2i sync defaults to main-temp"
  else
    pass "T2i sync does not default to main-temp"
  fi
fi

# ---- stub msmtp ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin" "$TMP/state" "$TMP/sb/s3"
cat > "$TMP/stubbin/msmtp" <<'EOF'
#!/usr/bin/env bash
echo "MSMTP_ARGS: $*" >> "$MAILBOX"
cat >> "$MAILBOX"
echo "---MAIL-END---" >> "$MAILBOX"
exit 0
EOF
chmod +x "$TMP/stubbin/msmtp"
export PATH="$TMP/stubbin:$PATH"
export MAILBOX="$TMP/mailbox"
: > "$MAILBOX"

run_check() {
  # $1 = last-sync content (or __MISSING__), remaining env via STORAGEBOX_* vars
  local content="$1"
  if [[ "$content" == "__MISSING__" ]]; then
    rm -f "$TMP/sb/s3/.last-sync"
  else
    printf '%s' "$content" > "$TMP/sb/s3/.last-sync"
  fi
  : > "$MAILBOX"
  rm -f "$TMP/state/staleness.state"
}

NOW_EPOCH="$(date +%s)"

# ---- T3: fresh marker is OK, no mail ----
FRESH="$(date -u -d "@$(( NOW_EPOCH - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')"
run_check "$FRESH"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" bash "$SCRIPT" >/tmp/t3.out 2>&1; then
  pass "T3 fresh marker exits 0"
else
  fail "T3 fresh marker exits 0"; cat /tmp/t3.out
fi
if grep -q "MSMTP_ARGS" "$MAILBOX"; then fail "T3 no mail on fresh"; else pass "T3 no mail on fresh"; fi

# ---- T4: stale marker FAILs and pages prod recipients ----
STALE="$(date -u -d "@$(( NOW_EPOCH - 200000 ))" '+%Y-%m-%dT%H:%M:%SZ')"
run_check "$STALE"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" bash "$SCRIPT" >/tmp/t4.out 2>&1; then
  fail "T4 stale exits nonzero"
else
  pass "T4 stale exits nonzero"
fi
if grep -q "MSMTP_ARGS" "$MAILBOX" && grep -q "alexey@datatalks.club" "$MAILBOX" && grep -q "dev@dtcdev.click" "$MAILBOX"; then
  pass "T4 stale pages both prod recipients"
else
  fail "T4 stale pages both prod recipients"; cat "$MAILBOX" 2>/dev/null
fi

# ---- T5: DRY_RUN would-alert but sends nothing ----
run_check "$STALE"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" DRY_RUN=1 bash "$SCRIPT" >/tmp/t5.out 2>&1; then
  fail "T5 DRY_RUN stale exits nonzero"
else
  pass "T5 DRY_RUN stale exits nonzero"
fi
if grep -q "DRY_RUN would-alert" /tmp/t5.out && ! grep -q "MSMTP_ARGS" "$MAILBOX"; then
  pass "T5 DRY_RUN would-alert, sends nothing"
else
  fail "T5 DRY_RUN would-alert, sends nothing"; cat /tmp/t5.out
fi

# ---- T6: drill pages ops-only ----
run_check "$FRESH"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" STORAGEBOX_STALE_DRILL=1 bash "$SCRIPT" >/tmp/t6.out 2>&1; then
  fail "T6 drill exits nonzero"
else
  pass "T6 drill exits nonzero"
fi
if grep -q "MSMTP_ARGS" "$MAILBOX" && grep -q "dev@dtcdev.click" "$MAILBOX" && ! grep -q "alexey@datatalks.club" "$MAILBOX"; then
  pass "T6 drill pages dev-only"
else
  fail "T6 drill pages dev-only"; cat "$MAILBOX" 2>/dev/null
fi

# ---- T7: prune is dry-run by default (no deletions) ----
if STORAGEBOX_ROOT="$TMP/sb" bash "$REPO/backups/prune-storagebox.sh" 2>&1 | grep -q "DRY_RUN"; then
  pass "T7 prune dry-run default"
else
  fail "T7 prune dry-run default"
fi

# ---- T8: missing marker FAILs and pages prod ----
run_check "__MISSING__"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" bash "$SCRIPT" >/tmp/t8.out 2>&1; then
  fail "T8 missing exits nonzero"
else
  pass "T8 missing exits nonzero"
fi
if grep -q "MSMTP_ARGS" "$MAILBOX" && grep -q "missing" "$MAILBOX"; then
  pass "T8 missing pages prod"
else
  fail "T8 missing pages prod"; cat "$MAILBOX" 2>/dev/null
fi

# ---- T9: unparseable + future markers FAIL ----
run_check "not-a-timestamp"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" bash "$SCRIPT" >/tmp/t9.out 2>&1; then
  fail "T9 unparseable exits nonzero"
else
  pass "T9 unparseable exits nonzero"
fi
FUTURE="$(date -u -d "@$(( NOW_EPOCH + 7200 ))" '+%Y-%m-%dT%H:%M:%SZ')"
run_check "$FUTURE"
if STORAGEBOX_ROOT="$TMP/sb" LAST_SYNC_FILE="$TMP/sb/s3/.last-sync" STATE_DIR="$TMP/state" \
  STORAGEBOX_NOW="$NOW_EPOCH" bash "$SCRIPT" >/tmp/t9b.out 2>&1; then
  fail "T9b future exits nonzero"
else
  pass "T9b future exits nonzero"
fi

echo "RESULT pass=$PASS fail=$FAILN"
[[ "$FAILN" -eq 0 ]]
