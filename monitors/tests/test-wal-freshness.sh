#!/usr/bin/env bash
# Exercise the production freshness function without running other probes or mail.
# Covers a3348a3e/t1862u: idle-DB tolerance, race re-read, real-stop paging,
# and the timestamp+segment alert enrichment (AC2/AC3).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Functions are loaded only; the production script entrypoint never runs.
# shellcheck disable=SC1090
source <(sed -n \
  -e '/^wal_archiver_snapshot() {/,/^}/p' \
  -e '/^wal_spool_pending() {/,/^}/p' \
  -e '/^wal_idle_verdict() {/,/^}/p' \
  -e '/^check_wal_freshness() {/,/^}/p' \
  "$ROOT/monitors/coolify-healthcheck.sh")
log() { printf '%s\n' "$*"; }
send_alert() { printf 'ALERT %s %s\n' "$1" "$3"; }
mark_ok() { printf 'HEALTHY %s\n' "$1"; }
export WAL_STATE_DIR="$TMP"
STATE_DIR="$TMP/health-state"
mkdir -p "$STATE_DIR"
WAL_STACKS='pg-shared pg-relay'
export WAL_STALE_SECONDS=1200
export WAL_IDLE_VERIFY=1
export WAL_IDLE_REREAD_WAIT_SEC=0.1

# 1. Garbage timestamps fail closed (never interpreted as midnight).
for value in '' '   ' yesterday '2026-99-28T02:55:04Z'; do
  printf '%s\n' "$value" > "$TMP/last-success-pg-shared"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-relay"
  FAILED=0
  check_wal_freshness > "$TMP/log"
  [[ "$FAILED" == 1 ]]
  grep -Eq 'invalid|unparseable' "$TMP/log"
  grep -q 'HEALTHY wal-pg-relay' "$TMP/log"
  ! grep -q 'age=.*last=$' "$TMP/log"
done
echo 'PASS empty, whitespace, relative and impossible dates fail closed; relay still checked'

# 2. Fresh timestamps are healthy for both stacks (no DB verification needed).
for stack in $WAL_STACKS; do date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-$stack"; done
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 0 ]]
grep -q 'HEALTHY wal-pg-shared' "$TMP/log"
grep -q 'HEALTHY wal-pg-relay' "$TMP/log"
echo 'PASS fresh timestamps healthy for both stacks'

# Stub snapshots/spool for the stale-age scenarios below.
SNAP_FILE="$TMP/snapshot.txt"
: > "$SNAP_FILE"
REAL_SNAPSHOT_SRC="$(declare -f wal_archiver_snapshot)"
REAL_SPOOL_SRC="$(declare -f wal_spool_pending)"
wal_archiver_snapshot() { cat "$SNAP_FILE"; }
wal_spool_pending() { printf '%s\n' "${SPOOL_PENDING:-0}"; }

# 3. Genuinely stale with verification disabled still alerts (old behavior).
date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-shared"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-relay"
WAL_IDLE_VERIFY=0
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 1 ]]
grep -q 'ALERT wal-pg-shared WAL archive stale' "$TMP/log"
echo 'PASS genuinely stale timestamps still alert with WAL_IDLE_VERIFY=0'

# 4. Stale age + archiver caught up + spool empty -> idle, NO page (AC2).
WAL_IDLE_VERIFY=1
SPOOL_PENDING=0
printf '0000000100000006000000FC|120|0|1761|0000000100000006000000FD\n' > "$SNAP_FILE"
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 0 ]]
grep -q 'HEALTHY wal-pg-shared' "$TMP/log"
grep -q 'archiver idle' "$TMP/log"
grep -q '0000000100000006000000FC' "$TMP/log"
[[ "$(tr -d '[:space:]' < "$STATE_DIR/wal-archiver-failed-pg-shared")" == 0 ]]
echo 'PASS stale age with idle archiver and empty spool does not page; failed_count baseline tracked'

# 5. Unarchived backlog (>=2 segments) pages and names the segments (AC2+AC3).
date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-shared"
printf '0000000100000006000000FC|1900|0|1761|0000000100000006000000FE\n' > "$SNAP_FILE"
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 1 ]]
grep -q 'ALERT wal-pg-shared WAL archive stale' "$TMP/log"
grep -q 'unarchived backlog' "$TMP/log"
grep -q '0000000100000006000000FC' "$TMP/log"
grep -q '0000000100000006000000FE' "$TMP/log"
grep -q "last success $(cat "$TMP/last-success-pg-shared")" "$TMP/log"
echo 'PASS backlog pages with timestamp and segment of the last archived success'

# 6. failed_count increase pages even without segment backlog.
printf '0000000100000006000000FC|1900|7|1761|0000000100000006000000FD\n' > "$SNAP_FILE"
printf '3\n' > "$STATE_DIR/wal-archiver-failed-pg-shared"
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 1 ]]
grep -q 'failed_count rose 3->7' "$TMP/log"
echo 'PASS archiver failed_count increase pages'

# 7. Non-empty spool pages (shipper/S3 leg stuck) even when the DB is idle.
printf '0000000100000006000000FC|1900|0|1761|0000000100000006000000FD\n' > "$SNAP_FILE"
rm -f "$STATE_DIR/wal-archiver-failed-pg-shared"
SPOOL_PENDING=2
check_wal_freshness > "$TMP/log"
grep -q 'spool holds 2 unshipped segment' "$TMP/log"
echo 'PASS unshipped spool segments page even with a caught-up archiver'

# 8. Verification impossible (DB unreachable) fails closed -> still pages.
: > "$SNAP_FILE"
wal_archiver_snapshot() { return 1; }
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 1 ]]
grep -q 'failing closed' "$TMP/log"
echo 'PASS unavailable archiver verification fails closed and pages'

# 9. Race regression (2026-10-28T02:55Z): first read sees the truncated state
# file, shipper completes the write during the re-read wait -> no page.
wal_archiver_snapshot() { cat "$SNAP_FILE"; }  # restore (must not be reached)
printf '0000000100000006000000FC|120|0|1761|0000000100000006000000FD\n' > "$SNAP_FILE"
printf '' > "$TMP/last-success-pg-shared"
sleep() { date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-shared"; }  # stub: shipper publishes during the wait
FAILED=0
check_wal_freshness > "$TMP/log"
unset -f sleep
[[ "$FAILED" == 0 ]]
grep -q 'HEALTHY wal-pg-shared' "$TMP/log"
echo 'PASS empty read followed by shipper publish during re-read wait does not page'

# 10. wal_archiver_snapshot / wal_spool_pending parse a container-mode stub
# end to end (docker exec -> fake psql; docker inspect -> fake mount).
eval "$REAL_SNAPSHOT_SRC"   # restore the real helpers from before the stubs
eval "$REAL_SPOOL_SRC"
FAKE_PSQL="$TMP/fake-psql"
mkdir -p "$TMP/realbin" "$TMP/pgdata/wal_spool"
cat > "$FAKE_PSQL" <<'STUB'
#!/usr/bin/env bash
printf '0000000100000006000000FC|42|1|99|0000000100000006000000FD\n'
STUB
cat > "$TMP/realbin/docker" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "exec" ]]; then shift 4; exec "$FAKE_PSQL" "\$@"; fi
if [[ "\$1" == "inspect" ]]; then echo "$TMP/pgdata"; exit 0; fi
exit 64
STUB
chmod +x "$FAKE_PSQL" "$TMP/realbin/docker"
out="$(PG_SHARED_CONTAINER=fake-ctr PATH="$TMP/realbin:$PATH" wal_archiver_snapshot pg-shared)"
[[ "$out" == '0000000100000006000000FC|42|1|99|0000000100000006000000FD' ]]
out="$(PATH="$TMP/realbin:$PATH" wal_spool_pending fake-ctr)"
[[ "$out" == 0 ]]
touch "$TMP/pgdata/wal_spool/0000000100000006000000FE"
out="$(PATH="$TMP/realbin:$PATH" wal_spool_pending fake-ctr)"
[[ "$out" == 1 ]]
echo 'PASS snapshot/spool helpers work through the docker exec/inspect path'

echo 'ALL WAL FRESHNESS TESTS PASSED'
