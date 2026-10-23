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
#     --wal-dir /path/to/wal/ [--recovery-target '<time|lsn|xid|latest>'
#     --recovery-target-action promote|pause|shutdown]
# --wal-dir holds archived segments after it (--base-wal end). Segments may be
# bare (`0000000100000000000000AB`) or gzipped (`...AB.gz`, as produced by
# coolify-wal-shipper.sh S3 layout); .gz files are integrity-checked
# (gzip -t) and decompressed — never silently skipped. Known pg_basebackup
# artifacts (`<seg>.backup[gz]`) are staged, not replayed. Any other file, a
# corrupt archive, or a gap in the segment sequence FAILS LOUDLY.
# --recovery-target pins the replay end: 'YYYY-MM-DD HH:MM:SS+TZ' (validated
# via date -d), '0/1A2B3C' LSN, numeric XID, or 'latest' (replay to tip).
# Continuity is verified from the base backup_label START segment through the
# staged tip, so a missing leading/trailing segment cannot replay silently.
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
RECOVERY_TARGET="latest"; RECOVERY_TARGET_ACTION="promote"
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
    --recovery-target) RECOVERY_TARGET="$2"; shift 2 ;;
    --recovery-target-action) RECOVERY_TARGET_ACTION="$2"; shift 2 ;; 
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

# ---- recovery-target validation (pitr only; dump ignores these) ----
# Accepted: 'latest' (replay to tip), timestamptz, LSN (X/X hex), or XID.
RECOVERY_KIND=""
if [[ "$MODE" == "pitr" ]]; then
  case "$RECOVERY_TARGET_ACTION" in
    promote|pause|shutdown) ;;
    *) fail "--recovery-target-action must be promote|pause|shutdown (got: $RECOVERY_TARGET_ACTION)" ;;
  esac
  if [[ "$RECOVERY_TARGET" == "latest" ]]; then
    RECOVERY_KIND="latest"
  elif [[ "$RECOVERY_TARGET" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]]; then
    RECOVERY_KIND="lsn"
  elif [[ "$RECOVERY_TARGET" =~ ^[0-9]+$ ]]; then
    RECOVERY_KIND="xid"
  elif [[ "$RECOVERY_TARGET" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})? ]]; then
    CANON="$(date -u -d "$RECOVERY_TARGET" '+%Y-%m-%d %H:%M:%S%z' 2>/dev/null)" \
      || fail "--recovery-target is not a parseable timestamp: $RECOVERY_TARGET"
    RECOVERY_TARGET="$CANON"
    RECOVERY_KIND="time"
  else
    fail "--recovery-target must be 'latest', a timestamp (YYYY-MM-DD HH:MM[:SS][TZ]), an LSN (X/X), or a numeric XID (got: $RECOVERY_TARGET)"
  fi
  log "recovery target: kind=$RECOVERY_KIND value=$RECOVERY_TARGET action=$RECOVERY_TARGET_ACTION"
fi

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
  # Read the base START segment BEFORE the chown handoff below (after chown
  # our uid can no longer read pgdata). Needed for WAL continuity validation.
  STARTSEG=""
  if [[ -f "$PGDATA/backup_label" ]]; then
    STARTSEG="$(grep -a -o '(file [0-9A-F]\{24\})' "$PGDATA/backup_label" | head -1 | grep -a -o '[0-9A-F]\{24\}')"
  fi
  printf "restore_command = 'cp /wal/%%f %%p'\n" > "$PGDATA/postgresql.auto.conf.restore"
  cat "$PGDATA/postgresql.auto.conf.restore" >> "$PGDATA/postgresql.auto.conf"
  rm -f "$PGDATA/postgresql.auto.conf.restore"
  if [[ "$RECOVERY_KIND" == "time" ]]; then
    printf "recovery_target_time = '%s'\nrecovery_target_action = '%s'\n" \
      "$RECOVERY_TARGET" "$RECOVERY_TARGET_ACTION" >> "$PGDATA/postgresql.auto.conf"
  elif [[ "$RECOVERY_KIND" == "lsn" ]]; then
    printf "recovery_target_lsn = '%s'\nrecovery_target_action = '%s'\n" \
      "$RECOVERY_TARGET" "$RECOVERY_TARGET_ACTION" >> "$PGDATA/postgresql.auto.conf"
  elif [[ "$RECOVERY_KIND" == "xid" ]]; then
    printf "recovery_target_xid = '%s'\nrecovery_target_action = '%s'\n" \
      "$RECOVERY_TARGET" "$RECOVERY_TARGET_ACTION" >> "$PGDATA/postgresql.auto.conf"
  fi
  touch "$PGDATA/recovery.signal"
  # Files extract as our uid; the container runs postgres as its own uid, so
  # hand ownership over from INSIDE the image (container root has CAP_CHOWN —
  # a non-root operator cannot chown to another uid on the host).
  docker run --rm --entrypoint /bin/chown -v "$PGDATA:/w/pgdata" "$PG_IMAGE" \
    -R postgres:postgres /w/pgdata >/dev/null || fail "chown of staged pgdata failed"
  # Stage a world-readable WAL copy (inputs may be 600; never mutate caller's dir).
  # .gz segments (coolify-wal-shipper.sh S3 layout) are integrity-checked and
  # decompressed to bare names; anything else FAILS LOUDLY — never skipped.
  # Empty --wal-dir, or a --wal-dir with zero usable segments, fails: an
  # explicit dir that stages nothing is almost certainly a mistake, and a
  # silent base-only replay would masquerade as PITR.
  WALCOPY="$WORKDIR/wal"; mkdir -p "$WALCOPY"
  if [[ -n "$WALDIR" ]]; then
    STAGED=0
    while IFS= read -r -d '' SRC; do
      FN="$(basename "$SRC")"
      if [[ "$FN" == *.gz ]]; then
        BARE="${FN%.gz}"
        if [[ "$BARE" =~ ^[0-9A-F]{24}$ ]]; then
          gzip -t "$SRC" || fail "WAL segment is CORRUPT (gzip -t failed): $FN"
          gzip -dc "$SRC" > "$WALCOPY/$BARE" \
            || fail "WAL segment decompress failed: $FN"
          STAGED=$((STAGED + 1))
        elif [[ "$BARE" =~ ^[0-9A-F]{24}(\.[0-9A-F]{8})?\.backup$ ]]; then
          gzip -t "$SRC" || fail "WAL .backup file is CORRUPT (gzip -t failed): $FN"
          gzip -dc "$SRC" > "$WALCOPY/$BARE" \
            || fail "WAL .backup decompress failed: $FN"
          STAGED=$((STAGED + 1))
        else
          fail "WAL input has unexpected name (want 24-hex segment [+ .gz]): $FN"
        fi
      elif [[ "$FN" =~ ^[0-9A-F]{24}$ || "$FN" =~ ^[0-9A-F]{8}\.history$ || "$FN" =~ ^[0-9A-F]{24}(\.[0-9A-F]{8})?\.backup$ ]]; then
        cp "$SRC" "$WALCOPY/$FN" || fail "WAL stage copy failed: $FN"
        STAGED=$((STAGED + 1))
      else
        fail "WAL input has unexpected name (want 24-hex segment [+ .gz]): $FN"
      fi
    done < <(find "$WALDIR" -maxdepth 1 -type f -print0)
    [[ "$STAGED" -gt 0 ]] \
      || fail "--wal-dir holds zero usable WAL segments: $WALDIR"
    log "staged $STAGED WAL file(s) from $WALDIR"
    # Continuity check: sequence must include the base backup_label START
    # segment and increment by 1 with no gaps (same timeline). A gap means
    # replay would stop mid-chain and promote a partial timeline — fail now.
    # (STARTSEG was captured before the chown handoff; pgdata is no longer
    # readable by our uid here.)
    [[ -n "$STARTSEG" ]] \
      || fail "base backup_label missing START segment — cannot verify WAL continuity"
    log "base START segment: $STARTSEG"
    PREV=""
    BEGUN=0
    while IFS= read -r SEG; do
      if [[ "$BEGUN" -eq 0 ]]; then
        # Segments older than the base START are harmless (restore never
        # requests them) — skip, but the START segment itself must exist.
        [[ "$SEG" < "$STARTSEG" ]] && continue
        [[ "$SEG" == "$STARTSEG" ]] \
          || fail "WAL GAP: staged chain starts at $SEG but base needs $STARTSEG"
        BEGUN=1
      else
        if [[ "${SEG:0:16}" != "${PREV:0:16}" ]]; then
          fail "WAL TIMELINE CHANGE unsupported ($PREV -> $SEG) — investigate, refusing silent replay"
        fi
        WANT="$(printf '%08X' $((16#${PREV:16:8} + 1)))"
        [[ "${SEG:16:8}" == "$WANT" ]] \
          || fail "WAL GAP: after $PREV expected ${PREV:0:16}${WANT} but chain has $SEG"
      fi
      PREV="$SEG"
    done < <(ls "$WALCOPY" | grep -E '^[0-9A-F]{24}$' | sort)
    [[ "$BEGUN" -eq 1 ]] \
      || fail "WAL GAP: base START segment $STARTSEG not present in staged WAL"
    log "WAL chain continuous: $STARTSEG .. $PREV"
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
  # Wait for recovery to finish (replay to tip of available WAL, or to the
  # explicit --recovery-target). A torn/missing tail segment makes Postgres
  # retry restore_command forever — the loop below times out and fails LOUDLY
  # with the tail of the recovery log instead of promoting a gapped timeline.
  # NOTE: local-socket exec as the image superuser — the restored instance
  # keeps its ORIGINAL password, which we do not know (and never ask for).
  # TARGET_DB must exist in the restored cluster (it does — same DBs as prod).
  for _ in $(seq 1 60); do
    INREC="$(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo "?")"
    [[ "$INREC" == "f" ]] && break
    sleep 2
  done
  if [[ "$INREC" != "f" ]]; then
    log "ERROR: recovery log tail (why replay is stuck):"
    docker logs "$RUN_ID" 2>&1 | grep -a -E 'FATAL|ERROR|WARNING|restore|recovery|WAL|target' | tail -20 || true
    fail "instance still in recovery after 120s (WAL gap, torn tail, or unreachable target) — refusing to promote"
  fi
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
