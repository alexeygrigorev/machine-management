#!/usr/bin/env bash
# Dry-run reproduction for a3348a3e/t1862u against the REAL healthcheck
# entrypoint: a stale shipper last-success must NOT page when the archiver is
# caught up and the spool is empty (idle DB), but must still page — naming the
# last success timestamp and segment — when unarchived WAL backs up.
# Hermetic: fake env file, docker/psql/curl/msmtp/sendmail stubs, no network,
# non-routable recipient; mail is captured to a stub file, never sent.
# (Without the MTA stub the script's default env path on a dev host can be
# sourced and would page real recipients — do not remove these stubs.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SNAPSHOT="$TMP/snapshot.txt"
PGDATA="$TMP/pgdata"
STUB_MAIL="$TMP/stub-mail.log"
mkdir -p "$PGDATA/wal_spool" "$TMP/bin" "$TMP/state-shipper"
: > "$STUB_MAIL"

cat > "$TMP/fake-psql" <<STUB
#!/usr/bin/env bash
cat "$SNAPSHOT"
STUB
cat > "$TMP/bin/docker" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "exec" ]]; then shift 4; exec "$TMP/fake-psql" "\$@"; fi
if [[ "\$1" == "inspect" ]]; then echo "$PGDATA"; exit 0; fi
exit 64
STUB
cat > "$TMP/bin/msmtp" <<'EOF'
#!/usr/bin/env bash
echo "MSMTP_ARGS: $*" >> "$STUB_MAIL"
cat >> "$STUB_MAIL"
printf '\n---\n' >> "$STUB_MAIL"
EOF
cp "$TMP/bin/msmtp" "$TMP/bin/sendmail"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL: $*" >> "$STUB_MAIL"
exit 0
EOF
chmod +x "$TMP/fake-psql" "$TMP/bin/docker" "$TMP/bin/msmtp" "$TMP/bin/sendmail" "$TMP/bin/curl"

run_healthcheck() {
  PATH="$TMP/bin:$PATH" \
  COOLIFY_HEALTHCHECK_ENV_FILE="$TMP/absent-env" \
  ALERT_TO=healthcheck-dryrun@invalid ALERT_MSMTP_ACCOUNT="" \
  STATE_DIR="$TMP/state" LOCK_FILE="$TMP/lock" \
  WAL_SHIPPER_STATE_DIR="$TMP/state-shipper" WAL_STACKS="pg-shared" WAL_STALE_SECONDS=1200 \
  WAL_IDLE_REREAD_WAIT_SEC=0.1 \
  SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_DISK_CHECK=1 SKIP_CREATED_CHECK=1 \
  SKIP_BACKUP_CHECKS=0 EXPECT_DBS="cmp" DUMP_DIR="$TMP/dumps" \
  APP_URLS="" CONTENT_CHECKS="" \
  LATENCY_PROBES="" LATENCY_PUSH_ENABLED=0 \
  CHECK_CMP_CALLBACKS=0 CHECK_AISL_Q=0 \
  PG_SHARED_CONTAINER=fake-ctr PGUSER_SHARED=pgadmin PG_SHARED_DB=postgres \
  bash "$ROOT/monitors/coolify-healthcheck.sh" > "$TMP/run.log" 2>&1
}
export STUB_MAIL
# Fresh dump artifact so the (real) dump-freshness check passes.
mkdir -p "$TMP/dumps"
touch "$TMP/dumps/cmp-$(date -u '+%Y%m%dT%H%M').dump.gz"

# --- Scenario A (the false page): last success 30 min old, nothing wrong.
date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/state-shipper/last-success-pg-shared"
printf '0000000100000006000000FC|120|0|1761|0000000100000006000000FD\n' > "$SNAPSHOT"
rm -f "$PGDATA/wal_spool"/*
run_healthcheck && rc=0 || rc=$?
[[ "$rc" == 0 ]] || { cat "$TMP/run.log"; exit 1; }
grep -q 'wal-pg-shared.*archiver idle' "$TMP/run.log"
grep -q 'ALL_OK' "$TMP/run.log"
grep -q '0000000100000006000000FC' "$TMP/run.log"
! grep -q 'MSMTP_ARGS' "$STUB_MAIL"
echo 'PASS dry-run: stale age + idle archiver + empty spool = ALL_OK, no mail'

# --- Scenario B (a real stop): archiver two segments behind -> page naming
# the last success timestamp and segment (AC2 + AC3).
date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/state-shipper/last-success-pg-shared"
printf '0000000100000006000000FC|1900|0|1761|0000000100000006000000FE\n' > "$SNAPSHOT"
rm -f "$TMP/state/wal-pg-shared.state"
run_healthcheck && rc=0 || rc=$?
[[ "$rc" == 1 ]] || { cat "$TMP/run.log"; exit 1; }
grep -q 'unarchived backlog' "$TMP/run.log"
grep -q 'CHECKS_FAILED' "$TMP/run.log"
grep -q "last=$(cat "$TMP/state-shipper/last-success-pg-shared")" "$TMP/run.log"
grep -q '0000000100000006000000FC' "$TMP/run.log"
grep -q '0000000100000006000000FE' "$TMP/run.log"
grep -q 'MSMTP_ARGS' "$STUB_MAIL"
grep -q "last success $(cat "$TMP/state-shipper/last-success-pg-shared")" "$STUB_MAIL"
grep -q '0000000100000006000000FC' "$STUB_MAIL"
echo 'PASS dry-run: unarchived backlog pages with timestamp and segment of last success'

# --- Scenario C (the 02:55Z race): state file read empty mid-publish; the
# shipper completes the write during the re-read wait -> healthy, no page.
printf '0000000100000006000000FC|120|0|1761|0000000100000006000000FD\n' > "$SNAPSHOT"
rm -f "$PGDATA/wal_spool"/*
printf '' > "$TMP/state-shipper/last-success-pg-shared"
( sleep 0.05; date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/state-shipper/last-success-pg-shared" ) &
writer=$!
run_healthcheck && rc=0 || rc=$?
wait "$writer" 2>/dev/null || true
[[ "$rc" == 0 ]] || { cat "$TMP/run.log"; exit 1; }
grep -q 'ALL_OK' "$TMP/run.log"
echo 'PASS dry-run: empty mid-publish read recovers via bounded re-read'

echo 'ALL WAL IDLE DRY-RUN TESTS PASSED'
