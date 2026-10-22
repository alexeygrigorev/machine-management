#!/usr/bin/env bash
# fast-pg-raise.sh — scripted fastest raise of replacement Postgres from
# latest off-host dumps (storagebox and/or S3 copies).
#
# Design goals (t1037u experiment):
# - Pinned image only (no :latest): postgres:16.15-alpine
# - Loopback bind only (never public prod): 127.0.0.1:<PORT>
# - Single replacement instance hosting all logical DBs (fewer initdb waits)
# - Parallel pg_restore: DBs concurrently, -j jobs each
# - Warm image path: `docker pull` done before T0; timed separately
#
# Usage:
#   PORT=55437 ./contingency/fast-pg-raise.sh
#
# Env overrides:
#   CONTAINER   (default pg-fast-raise-t1037u)
#   PORT        (default 55437)
#   IMAGE       (default postgres:16.15-alpine)
#   PGUSER      (default drill_admin)
#   PGPW_FILE   (default $HOME/tmp/secrets/pg-fast-raise-t1037u.pw; generated if missing)
#   DUMPS_DIR   (default $HOME/tmp/pg-fast-raise-t1037u/dumps; storagebox copies staged here)
#   JOBS        (default 4, passed as pg_restore -j)
#   DBS         (default "cmp aisl website relay")
#
# Dumps expected in DUMPS_DIR as: <db>.dump  (e.g. cmp.dump, aisl.dump, ...)
# Exit codes: 0 all restores exit 0; non-zero otherwise.
set -euo pipefail

CONTAINER="${CONTAINER:-pg-fast-raise-t1037u}"
PORT="${PORT:-55437}"
IMAGE="${IMAGE:-postgres:16.15-alpine}"
PGUSER="${PGUSER:-drill_admin}"
PGPW_FILE="${PGPW_FILE:-$HOME/tmp/secrets/pg-fast-raise-t1037u.pw}"
DUMPS_DIR="${DUMPS_DIR:-$HOME/tmp/pg-fast-raise-t1037u/dumps}"
JOBS="${JOBS:-4}"
DBS="${DBS:-cmp aisl website relay}"

log() { printf '[fast-pg-raise %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

if [ ! -f "$PGPW_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 >"$PGPW_FILE"
  chmod 600 "$PGPW_FILE"
  log "generated PG password at $PGPW_FILE"
fi
PGPASSWORD="$(cat "$PGPW_FILE")"
export PGPASSWORD

for db in $DBS; do
  if [ ! -f "$DUMPS_DIR/$db.dump" ]; then
    echo "missing dump: $DUMPS_DIR/$db.dump" >&2
    exit 2
  fi
done

log "image=$IMAGE (must be pre-pulled for warm RTO)"
docker pull "$IMAGE" >/dev/null
log "image ready: $(docker images --no-trunc "$IMAGE" --format '{{.Digest}}' 2>/dev/null || true)"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "removing previous container/volume $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "${CONTAINER}-data" >/dev/null 2>&1 || true
fi

log "starting $CONTAINER on 127.0.0.1:$PORT"
docker run -d --name "$CONTAINER" --restart=no \
  -e POSTGRES_USER="$PGUSER" \
  -e POSTGRES_PASSWORD="$PGPASSWORD" \
  -e POSTGRES_DB=postgres \
  -v "${CONTAINER}-data:/var/lib/postgresql/data" \
  -p "127.0.0.1:$PORT:5432" \
  "$IMAGE" >/dev/null

log "waiting for pg_isready"
for i in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U "$PGUSER" -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [ "$i" = 60 ]; then echo "pg never became ready" >&2; exit 3; fi
done
log "postgres ready"

for db in $DBS; do
  docker exec "$CONTAINER" createdb -U "$PGUSER" "$db" 2>/dev/null || true
  docker cp "$DUMPS_DIR/$db.dump" "$CONTAINER:/tmp/$db.dump"
done
log "databases created + dumps staged: $DBS"

LOGDIR="${LOGDIR:-$HOME/tmp/pg-fast-raise-t1037u/logs}"
mkdir -p "$LOGDIR"
log "restoring $DBS in parallel (pg_restore -j $JOBS each)"
pids=""
for db in $DBS; do
  docker exec "$CONTAINER" \
    pg_restore --no-owner --no-acl -U "$PGUSER" -d "$db" -j "$JOBS" -v "/tmp/$db.dump" \
    >"$LOGDIR/$db.out" 2>"$LOGDIR/$db.err" &
  pids="$pids $!:$db"
done

fail=0
for entry in $pids; do
  pid="${entry%%:*}"; db="${entry##*:}"
  if wait "$pid"; then
    log "restore OK: $db"
  else
    log "restore FAILED($?): $db — tail:"
    tail -n 20 "$LOGDIR/$db.err" || true
    fail=1
  fi
done

log "verify:"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname IN ('cmp','aisl','website','relay') ORDER BY 1;"
for db in $DBS; do
  n="$(docker exec "$CONTAINER" psql -U "$PGUSER" -d "$db" -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public';" 2>/dev/null || echo '?')"
  log "public tables in $db: $n"
done

exit "$fail"
