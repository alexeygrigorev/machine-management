#!/usr/bin/env bash
# Weekly Contabo → alt-host (Hetzner) fast PG raise drill.
#
# Schedule: Sundays 04:30 Europe/Berlin (see weekly-fast-pg-raise.cron).
# Flow:
#   1) Fresh pg_dump -Fc from live Contabo Coolify PG (pg-shared + pg-relay)
#   2) SCP to Hetzner staging dir
#   3) Timed contingency/fast-pg-raise.sh (loopback only; no CF/DNS/RDS)
#   4) Push VictoriaMetrics metrics via push-dr-raise-metrics.sh
#   5) Tear down throwaway container/volume (default TEARDOWN=1)
#
# Does NOT flip prod. Does NOT touch RDS. Distinct container/port from
# one-shot drills (t1037u :55437, t1118u :55438) — weekly uses :55439.
#
# Locking: THIS script is the single lock owner ($LOCK, default
# /tmp/weekly-fast-pg-raise.lock). Do not wrap it in an outer `flock`
# (see weekly-fast-pg-raise.cron). Exit 75 + SKIP log line = lock contended.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAISE_SH="${RAISE_SH:-$REPO_ROOT/contingency/fast-pg-raise.sh}"
PUSH_SH="${PUSH_SH:-$REPO_ROOT/contingency/push-dr-raise-metrics.sh}"

STAMP="$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')"
STAGE="${STAGE:-$HOME/tmp/pg-fast-raise-weekly}"
RAW="$STAGE/raw"
DUMPS="$STAGE/dumps"
LOGDIR="$STAGE/logs"
mkdir -p "$RAW" "$DUMPS" "$LOGDIR" "$STAGE"

CONTAINER="${CONTAINER:-pg-fast-raise-weekly}"
PORT="${PORT:-55439}"
JOBS="${JOBS:-4}"
DBS="${DBS:-cmp aisl website relay}"
TEARDOWN="${TEARDOWN:-1}"
CONTABO_B="${CONTABO_B:-alexey@169.58.124.141}"
SSH_ID="${SSH_ID:-$HOME/.ssh/id_contabo}"
PGUSER_SHARED="${PGUSER_SHARED:-pgadmin}"
PGUSER_RELAY="${PGUSER_RELAY:-pgadmin}"

log() { printf '[weekly-fast-pg-raise %s] %s\n' "$(TZ=Europe/Berlin date -Iseconds)" "$*"; }

# Single lock owner: the script itself holds $LOCK for the whole run.
# The cron unit (weekly-fast-pg-raise.cron) must NOT wrap this script in
# another `flock` on the same file — that double-lock made every cron run
# a silent no-op ("another weekly raise is running", exit 0) since 2026-10-22.
# Contended (genuinely concurrent) run: SKIP line in the log + exit 75
# (EX_TEMPFAIL), so a no-op never looks like a success (no metrics update,
# no last_success.env touch, non-zero exit).
LOCK="${LOCK:-/tmp/weekly-fast-pg-raise.lock}"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "SKIP: another weekly raise is running (lock contended on $LOCK)"
  exit 75
fi

ssh_b() {
  ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$SSH_ID" "$CONTABO_B" "$@"
}

TEARDOWN_DONE=0
teardown_resources() {
  [[ "$TEARDOWN_DONE" == "1" ]] && return 0
  TEARDOWN_DONE=1
  if [[ -n "${REMOTE_DIR:-}" ]]; then
    ssh_b "rm -rf '${REMOTE_DIR}'" || true
  fi
  if [[ "$TEARDOWN" == "1" ]]; then
    log "teardown ${CONTAINER}"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "${CONTAINER}-data" >/dev/null 2>&1 || true
  fi
}
trap teardown_resources EXIT

log "start stamp=${STAMP} container=${CONTAINER} port=${PORT}"

mapfile -t _pgc < <(ssh_b 'sudo -n docker ps --filter label=coolify.resourceName=pg-shared --format "{{.Names}}"; sudo -n docker ps --filter label=coolify.resourceName=pg-relay --format "{{.Names}}"')
PG_SHARED_C="${_pgc[0]:-}"
PG_RELAY_C="${_pgc[1]:-}"
[[ -n "$PG_SHARED_C" ]] || { log "ERROR: pg-shared container not found"; exit 3; }
[[ -n "$PG_RELAY_C" ]] || { log "ERROR: pg-relay container not found"; exit 3; }
log "contabo-b pg-shared=${PG_SHARED_C} pg-relay=${PG_RELAY_C}"

REMOTE_DIR="/home/alexey/tmp/weekly-fast-pg-raise-dumps/${STAMP}"
ssh_b "mkdir -p '${REMOTE_DIR}'"

dump_one() {
  local stack="$1" container="$2" pguser="$3" db="$4"
  local remote="${REMOTE_DIR}/${db}-${stack}-${STAMP}.dump"
  log "dump ${stack}/${db}"
  ssh_b "sudo -n docker exec '${container}' pg_dump -U '${pguser}' -Fc -d '${db}' > '${remote}'"
}
dump_one pg-shared "$PG_SHARED_C" "$PGUSER_SHARED" cmp
dump_one pg-shared "$PG_SHARED_C" "$PGUSER_SHARED" aisl
dump_one pg-shared "$PG_SHARED_C" "$PGUSER_SHARED" website
dump_one pg-relay  "$PG_RELAY_C"  "$PGUSER_RELAY"  relay

log "scp dumps from contabo-b"
scp -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$SSH_ID" \
  "${CONTABO_B}:${REMOTE_DIR}/"*.dump "$RAW/"
cp -a "$RAW/cmp-pg-shared-${STAMP}.dump"     "$DUMPS/cmp.dump"
cp -a "$RAW/aisl-pg-shared-${STAMP}.dump"    "$DUMPS/aisl.dump"
cp -a "$RAW/website-pg-shared-${STAMP}.dump" "$DUMPS/website.dump"
cp -a "$RAW/relay-pg-relay-${STAMP}.dump"    "$DUMPS/relay.dump"
md5sum "$DUMPS"/*.dump | tee "$STAGE/dumps.md5" >/dev/null

if [[ -d "$HOME/storagebox/backups" ]]; then
  DAY="$(TZ=Europe/Berlin date '+%Y/%m/%d')"
  for pair in "cmp:cmp-pg" "aisl:aisl-pg" "website:website-pg" "relay:relay-pg"; do
    db="${pair%%:*}"; dir="${pair##*:}"
    mkdir -p "$HOME/storagebox/backups/${dir}/${DAY}"
    cp -a "$RAW/${db}"*-"${STAMP}.dump" "$HOME/storagebox/backups/${dir}/${DAY}/" 2>/dev/null || true
  done
fi

docker pull "${IMAGE:-postgres:16.15-alpine}" >/dev/null

export CONTAINER PORT JOBS DBS
export DUMPS_DIR="$DUMPS"
export LOGDIR
export PGPW_FILE="${PGPW_FILE:-$HOME/tmp/secrets/pg-fast-raise-weekly.pw}"
mkdir -p "$(dirname "$PGPW_FILE")"

log "timed raise T0"
T0="$(date +%s)"
set +e
/usr/bin/time -o "$STAGE/official-time.txt" -v \
  bash "$RAISE_SH" >"$STAGE/official-raise.log" 2>&1
RC=$?
set -e
T1="$(date +%s)"
RTO=$((T1 - T0))
printf '%s\n' "$T0" >"$STAGE/T0_epoch"
printf '%s\n' "$T1" >"$STAGE/T1_epoch"
TZ=Europe/Berlin date -d "@$T0" -Iseconds >"$STAGE/OFFICIAL_T0"
TZ=Europe/Berlin date -d "@$T1" -Iseconds >"$STAGE/OFFICIAL_T1"
log "timed raise T1 rto=${RTO}s rc=${RC}"

SIZES_FILE="$STAGE/db-sizes.txt"
: >"$SIZES_FILE"
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  for db in $DBS; do
    bytes="$(docker exec "$CONTAINER" psql -U "${PGUSER:-drill_admin}" -d "$db" -tAc "SELECT pg_database_size(current_database());" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$bytes" =~ ^[0-9]+$ ]] && echo "$db $bytes" >>"$SIZES_FILE"
  done
fi

RESULT=fail
[[ "$RC" -eq 0 ]] && RESULT=pass
DB_SIZES_FILE="$SIZES_FILE" RESULT="$RESULT" RTO_SECONDS="$RTO" \
  bash "$PUSH_SH" || log "WARN: metric push failed (raise rc=${RC})"

teardown_resources

find "$HOME/tmp" -maxdepth 1 -type d -name 'pg-fast-raise-weekly*' -mtime +14 -exec rm -rf {} + 2>/dev/null || true

log "done result=${RESULT} rto=${RTO}s"
exit "$RC"
