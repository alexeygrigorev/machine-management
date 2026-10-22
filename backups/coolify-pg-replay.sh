#!/usr/bin/env bash
# Dump/base+WAL replay onto a throwaway Postgres — the CDC "replay everything"
# proof and the actual DR restore path.
#
# Mode dump (production-ready NOW, works with daily pg_dump output):
#   ./coolify-pg-replay.sh --mode dump --stack pg-shared --db cmp \
#     --dump /path/to/cmp-pg-shared-<STAMP>.dump[.gz] \
#     [--fetch-s3 s3://<bucket>/coolify/postgres/pg-shared/cmp/...dump.gz] \
#     [--expect-counts /path/to/source-census.txt]
#
# Mode pitr (works once WAL archiving is enabled via coolify-wal-enable.sh):
#   ./coolify-pg-replay.sh --mode pitr --stack pg-shared \
#     --base /path/to/pg-shared-base-<STAMP>.tar.gz \
#     --base-wal /path/to/pg-shared-pg_wal-<STAMP>.tar.gz \
#     --wal-dir /path/to/wal/
# --base-wal is the pg_wal.tar.gz member written by pg_basebackup -Ft -X
# stream (same STAMP as --base); --wal-dir holds archived segments after it.
# --db-user names the restored cluster's superuser for the census
# (prod Coolify clusters use pgadmin, not postgres).
# The WAL set must be COMPLETE: collect it after a clean source shutdown
# (a live tail segment is torn and replays forever — the script waits, then
# fails loudly rather than promoting a gapped timeline).
#
# Both modes: start a THROWAWAY postgres (pinned image, 127.0.0.1 only),
# restore/replay, run a per-table row census, compare with --expect-counts
# when given, print wall-clock TIMING + PASS/FAIL, then destroy the container
# and volume (unless --keep). Exit 0 only on census match (or, without
# --expect-counts, on clean restore + census written).
#
# Source census one-liner (run against prod; read-only, cheap at our sizes):
#   psql "$DATABASE_URL" -tAc \
#     "SELECT schemaname||'.'||tablename FROM pg_tables
#      WHERE schemaname NOT IN ('pg_catalog','information_schema')
#      ORDER BY 1;" | while read -r t; do
#       printf '%s %s\n' "$t" "$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM $t;")"
#     done | sort > source-census.txt
#
# Safety: never touches prod (no --prod flag exists by design); bind is
# forced to 127.0.0.1; image defaults to pinned postgres:16.15-alpine
# (matches prod PG16) — never :latest.
set -euo pipefail

MODE="dump"; STACK=""; DB=""; DUMP=""; FETCH_S3=""; EXPECT=""; KEEP=0
BASE=""; BASEWAL=""; WALDIR=""; DBUSER="postgres"
PG_IMAGE="${PG_IMAGE:-postgres:16.15-alpine}"
WORKDIR="${WORKDIR:-$(mktemp -d /tmp/pg-replay-XXXXXX)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --dump) DUMP="$2"; shift 2 ;;
    --fetch-s3) FETCH_S3="$2"; shift 2 ;;
    --expect-counts) EXPECT="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --base-wal) BASEWAL="$2"; shift 2 ;;
    --wal-dir) WALDIR="$2"; shift 2 ;;
    --db-user) DBUSER="$2"; shift 2 ;;
    --pg-image) PG_IMAGE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" ; }
fail() { log "ERROR: $*"; exit 1; }
[[ "$MODE" == "dump" || "$MODE" == "pitr" ]] || fail "--mode must be dump|pitr"
[[ "$PG_IMAGE" != *":latest"* ]] || fail "pinned image required, not :latest"

command -v docker >/dev/null 2>&1 || fail "missing binary: docker"
command -v psql >/dev/null 2>&1 || fail "missing binary: psql (apt install postgresql-client)"
command -v pg_restore >/dev/null 2>&1 || fail "missing binary: pg_restore"

RUN_ID="pgreplay-$$-$(date +%s)"
TARGET_DB="${DB:-replaydb}"
CENSUS="$WORKDIR/census.txt"
T0=$(date +%s)

cleanup() {
  if [[ "$KEEP" -eq 0 ]]; then
    docker rm -f "$RUN_ID" >/dev/null 2>&1 || true
    docker volume rm "${RUN_ID}-data" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" 2>/dev/null || \
      docker run --rm --entrypoint /bin/rm -v "$(dirname "$WORKDIR"):/w" "$PG_IMAGE" -rf "/w/$(basename "$WORKDIR")" >/dev/null 2>&1 || true
  else
    log "KEEP: container=$RUN_ID workdir=$WORKDIR (destroy by hand)"
  fi
}
trap cleanup EXIT

# Free 127.0.0.1 port in the drill range.
PORT=0
for p in $(shuf -i 55440-55540 -n 20); do
  (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 || { PORT=$p; break; }
done
[[ "$PORT" -ne 0 ]] || fail "no free drill port found"
PW="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"

census_of() {
  # $1=conn-target db name -> writes sorted "schema.table count" to $CENSUS + total
  local db="$1" out="$2" total=0
  : > "$out"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    c="$(PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U drill_admin -d "$db" -tAc "SELECT count(*) FROM $t;")"
    printf '%s %s\n' "$t" "$c" >> "$out"
    total=$((total + c))
  done < <(PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U drill_admin -d "$db" -tAc \
    "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;")
  sort -o "$out" "$out"
  printf 'TOTAL %s\n' "$total" >> "$out"
}

if [[ "$MODE" == "dump" ]]; then
  if [[ -n "$FETCH_S3" ]]; then
    command -v aws >/dev/null 2>&1 || fail "missing binary: aws (for --fetch-s3)"
    DUMP="$WORKDIR/fetch.dump.gz"
    log "fetching $FETCH_S3 ..."
    aws s3 cp "$FETCH_S3" "$DUMP" --only-show-errors || fail "S3 fetch failed"
  fi
  [[ -n "$DUMP" && -f "$DUMP" ]] || fail "--dump file missing (or use --fetch-s3)"
  [[ -n "$DB" ]] || fail "--db required in dump mode"

  log "starting throwaway $PG_IMAGE on 127.0.0.1:$PORT (stack=${STACK:-?} db=$DB) ..."
  docker run -d --name "$RUN_ID" --restart=no \
    -e POSTGRES_USER=drill_admin -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=postgres \
    -v "${RUN_ID}-data:/var/lib/postgresql/data" \
    -p "127.0.0.1:${PORT}:5432" "$PG_IMAGE" >/dev/null || fail "docker run failed"
  for _ in $(seq 1 30); do
    PGPASSWORD="$PW" pg_isready -h 127.0.0.1 -p "$PORT" -U drill_admin >/dev/null 2>&1 && break
    sleep 2
  done
  PGPASSWORD="$PW" pg_isready -h 127.0.0.1 -p "$PORT" -U drill_admin >/dev/null 2>&1 || fail "throwaway postgres never became ready"
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U drill_admin -d postgres -c "CREATE DATABASE $TARGET_DB;" >/dev/null

  T1=$(date +%s)
  if [[ "$DUMP" == *.gz ]]; then
    gzip -dc "$DUMP" > "$WORKDIR/restore.dump"
  else
    cp "$DUMP" "$WORKDIR/restore.dump"
  fi
  docker cp "$WORKDIR/restore.dump" "$RUN_ID:/tmp/restore.dump"
  log "pg_restore start db=$DB size=$(stat -c%s "$WORKDIR/restore.dump")B"
  docker exec "$RUN_ID" pg_restore --no-owner --no-acl -U drill_admin -d "$TARGET_DB" -v /tmp/restore.dump >"$WORKDIR/restore.log" 2>&1 \
    || { tail -5 "$WORKDIR/restore.log"; fail "pg_restore failed (see $WORKDIR/restore.log)"; }
  T2=$(date +%s)
  census_of "$TARGET_DB" "$CENSUS"
  T3=$(date +%s)
  log "census written: $(wc -l < "$CENSUS") tables, $(tail -1 "$CENSUS")"
else
  # ---- pitr mode: base tar + local WAL dir ----
  [[ -n "$BASE" && -f "$BASE" ]] || fail "--base tar.gz missing"
  # --wal-dir is OPTIONAL: without it, replay stops at the end of the
  # base's own WAL-stream window (exact backup-end state — still a full,
  # verified rebuild, RPO = base age). With archived segments it replays
  # forward to their tip.
  if [[ -n "$WALDIR" ]]; then [[ -d "$WALDIR" ]] || fail "--wal-dir missing: $WALDIR"; fi
  command -v tar >/dev/null 2>&1 || fail "missing binary: tar"
  PGDATA="$WORKDIR/pgdata"; mkdir -p "$PGDATA"
  chmod 755 "$WORKDIR"   # container postgres uid must traverse the bind mount
  log "extracting base ..."
  if [[ "$BASE" == *.gz ]]; then tar -xzf "$BASE" -C "$PGDATA"; else tar -xf "$BASE" -C "$PGDATA"; fi
  if [[ -n "$BASEWAL" ]]; then
    [[ -f "$BASEWAL" ]] || fail "--base-wal file missing: $BASEWAL"
    log "extracting base WAL-stream member ..."
    mkdir -p "$PGDATA/pg_wal"
    # NOTE: pg_wal.tar.gz members are bare segment names (no pg_wal/ prefix),
    # so extract into pgdata/pg_wal, NOT pgdata.
    if [[ "$BASEWAL" == *.gz ]]; then tar -xzf "$BASEWAL" -C "$PGDATA/pg_wal"; else tar -xf "$BASEWAL" -C "$PGDATA/pg_wal"; fi
  fi
  printf "restore_command = 'cp /wal/%%f %%p'\n" > "$PGDATA/postgresql.auto.conf.restore"
  cat "$PGDATA/postgresql.auto.conf.restore" >> "$PGDATA/postgresql.auto.conf"
  rm -f "$PGDATA/postgresql.auto.conf.restore"
  touch "$PGDATA/recovery.signal"
  # Files extract as our uid; the container runs postgres as its own uid, so
  # hand ownership over from INSIDE the image (container root has CAP_CHOWN —
  # a non-root operator cannot chown to another uid on the host).
  docker run --rm --entrypoint /bin/chown -v "$PGDATA:/w/pgdata" "$PG_IMAGE" \
    -R postgres:postgres /w/pgdata >/dev/null || fail "chown of staged pgdata failed"
  # Stage a world-readable WAL copy (inputs may be 600; never mutate caller's dir).
  # Empty when --wal-dir is absent: restore_command then fails fast and the
  # instance promotes at the end of the base's own WAL-stream window.
  WALCOPY="$WORKDIR/wal"; mkdir -p "$WALCOPY"
  if [[ -n "$WALDIR" ]]; then
    cp "$WALDIR"/0* "$WALCOPY"/ 2>/dev/null || cp -r "$WALDIR"/. "$WALCOPY"/
    chmod -R a+rX "$WALCOPY"
  fi
  log "starting throwaway $PG_IMAGE on 127.0.0.1:$PORT for WAL replay (stack=${STACK:-?}) ..."
  docker run -d --name "$RUN_ID" --restart=no \
    -e POSTGRES_PASSWORD="$PW" \
    -v "$PGDATA:/var/lib/postgresql/data" \
    -v "$WALCOPY:/wal:ro" \
    -p "127.0.0.1:${PORT}:5432" "$PG_IMAGE" >/dev/null || fail "docker run failed"
  T1=$T0
  TARGET_DB="${DB:-postgres}"
  for _ in $(seq 1 60); do
    PGPASSWORD="$PW" pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1 && break
    sleep 2
  done
  # Wait for recovery to finish (replay to tip of available WAL).
  # NOTE: local-socket exec as the image superuser — the restored instance
  # keeps its ORIGINAL password, which we do not know (and never ask for).
  # TARGET_DB must exist in the restored cluster (it does — same DBs as prod).
  for _ in $(seq 1 60); do
    INREC="$(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo "?")"
    [[ "$INREC" == "f" ]] && break
    sleep 2
  done
  [[ "$INREC" == "f" ]] || fail "instance still in recovery (WAL gap?)"
  # pitr census uses the image's postgres superuser via local socket (trust).
  CENSUS_TMP="$WORKDIR/census.txt"; : > "$CENSUS_TMP"; PTOTAL=0
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    c="$(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc "SELECT count(*) FROM $t;")"
    printf '%s %s\n' "$t" "$c" >> "$CENSUS_TMP"
    PTOTAL=$((PTOTAL + c))
  done < <(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc \
    "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;")
  sort -o "$CENSUS_TMP" "$CENSUS_TMP"; printf 'TOTAL %s\n' "$PTOTAL" >> "$CENSUS_TMP"
  CENSUS="$CENSUS_TMP"
  T2=$(date +%s); T3=$T2
  log "WAL replay complete, census: $(wc -l < "$CENSUS") tables, $(tail -1 "$CENSUS")"
fi

if [[ -n "$EXPECT" ]]; then
  [[ -f "$EXPECT" ]] || fail "--expect-counts file missing: $EXPECT"
  if diff -u "$EXPECT" "$CENSUS" >"$WORKDIR/census.diff"; then
    RESULT="PASS"
  else
    log "census MISMATCH:"; cat "$WORKDIR/census.diff"
    RESULT="FAIL"
  fi
else
  RESULT="OK-NO-EXPECT"
fi

SHA="$(sha256sum "$CENSUS" | cut -d' ' -f1)"
log "TIMING setup=$((T1 - T0))s restore=$((T2 - T1))s census=$((T3 - T2))s total=$((T3 - T0))s"
log "CENSUS_SHA256=$SHA"
log "RESULT=$RESULT"
[[ "$RESULT" != "FAIL" ]]
