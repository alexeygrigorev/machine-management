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
# (gzip -t) and decompressed on demand during recovery. Known pg_basebackup
# artifacts (`<seg>.backup[gz]`) are staged, not replayed. Any other file, a
# corrupt archive, or a gap in the segment sequence FAILS LOUDLY.
# --recovery-target pins the replay end: 'YYYY-MM-DD HH:MM:SS+TZ' (validated
# via date -d), '0/1A2B3C' LSN, numeric XID, or 'latest' (replay to tip).
# Continuity is verified from the base backup_label START segment through the
# staged tip, so a missing leading/trailing segment cannot replay silently.
#
# Both modes start a THROWAWAY postgres (pinned image, socket-only for PITR),
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
# Safety: never touches prod (no --prod flag exists by design); the dump
# restore binds to loopback only. The image defaults to postgres:16.15-alpine
# (matches prod PG16) — never :latest.
set -euo pipefail

MODE="dump"; STACK=""; DB=""; DUMP=""; FETCH_S3=""; EXPECT=""; KEEP=0
BASE=""; BASEWAL=""; WALDIR=""; DBUSER="postgres"
RECOVERY_TARGET="latest"; RECOVERY_TARGET_ACTION="promote"
PG_IMAGE="${PG_IMAGE:-postgres:16.15-alpine}"
REPLAY_TIMEOUT="${REPLAY_TIMEOUT:-1800}"
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
  [[ "$REPLAY_TIMEOUT" =~ ^[1-9][0-9]{0,5}$ ]] || fail "REPLAY_TIMEOUT must be a positive number of seconds"
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

if [[ "$MODE" == "dump" ]]; then
  PORT=0
  for p in $(shuf -i 55440-55540 -n 20); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 || { PORT=$p; break; }
  done
  [[ "$PORT" -ne 0 ]] || fail "no free drill port found"
fi
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
  chmod 711 "$WORKDIR"   # allow traversal without listing the private scratch directory
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
  cat >> "$PGDATA/postgresql.auto.conf" <<'RECOVERY'
restore_command = 'if [ -f "/wal/%f" ]; then cp "/wal/%f" "%p"; elif [ -f "/wal/%f.gz" ]; then gzip -dc "/wal/%f.gz" > "%p"; else exit 1; fi'
RECOVERY
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
  # Keep verified compressed files compressed. Recovery expands one segment
  # at a time. Never change permissions or contents in the caller's archive.
  # Empty --wal-dir, or a --wal-dir with zero usable segments, fails: an
  # explicit dir that stages nothing is almost certainly a mistake, and a
  # silent base-only replay would masquerade as PITR.
  WALCOPY="$WORKDIR/wal"; mkdir -p "$WALCOPY"
  if [[ -n "$WALDIR" ]]; then
    STAGED=0
    SEGMENTS=()
    while IFS= read -r -d '' SRC; do
      FN="$(basename "$SRC")"
      BARE="${FN%.gz}"
      [[ "$BARE" =~ ^[0-9A-F]{24}$ || "$BARE" =~ ^[0-9A-F]{8}\.history$ || \
         "$BARE" =~ ^[0-9A-F]{24}(\.[0-9A-F]{8})?\.backup$ ]] \
        || fail "WAL input has unexpected name (want 24-hex segment [+ .gz]): $FN"
      if [[ "$FN" == *.gz ]]; then
        gzip -t "$SRC" || fail "WAL input is CORRUPT (gzip -t failed): $FN"
      fi
      if [[ "$BARE" =~ ^[0-9A-F]{24}$ ]]; then SEGMENTS+=("$BARE"); fi
      install -m 0600 "$SRC" "$WALCOPY/$FN" || fail "WAL stage copy failed: $FN"
      STAGED=$((STAGED + 1))
    done < <(find "$WALDIR" -maxdepth 1 -type f -print0)
    [[ "$STAGED" -gt 0 ]] \
      || fail "--wal-dir holds zero usable WAL segments: $WALDIR"
    log "staged $STAGED WAL file(s) from $WALDIR"
    # Continuity check: sequence must include the base backup_label START
    # segment and increment by 1 with no gaps (same timeline). A gap means
    # replay would stop mid-chain and promote a partial timeline — fail now.
    [[ -n "$STARTSEG" ]] \
      || fail "base backup_label missing START segment — cannot verify WAL continuity"
    CONTROL=$(docker run --rm --network none -e LC_ALL=C --entrypoint pg_controldata \
      -v "$PGDATA:/w/pgdata:ro" "$PG_IMAGE" /w/pgdata) || fail "cannot read WAL segment size from pg_control"
    SEG_BYTES=$(awk -F: '/^Bytes per WAL segment:/ {gsub(/[[:space:]]/, "", $2); print $2}' <<< "$CONTROL")
    [[ "$SEG_BYTES" =~ ^[1-9][0-9]{6,9}$ ]] && (( SEG_BYTES >= 1048576 && SEG_BYTES <= 1073741824 && (SEG_BYTES & (SEG_BYTES - 1)) == 0 )) \
      || fail "invalid WAL segment size in pg_control: $SEG_BYTES"
    SEGMENTS_PER_LOG=$(( 0x100000000 / SEG_BYTES ))
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
        if [[ "${SEG:0:8}" != "${PREV:0:8}" ]]; then
          fail "WAL TIMELINE CHANGE unsupported ($PREV -> $SEG) — investigate, refusing silent replay"
        fi
        NEXT_INDEX=$((16#${PREV:16:8} + 1))
        NEXT_LOG=$((16#${PREV:8:8} + NEXT_INDEX / SEGMENTS_PER_LOG))
        printf -v WANT '%s%08X%08X' "${PREV:0:8}" "$NEXT_LOG" "$((NEXT_INDEX % SEGMENTS_PER_LOG))"
        [[ "$SEG" == "$WANT" ]] || fail "WAL GAP: after $PREV expected $WANT but chain has $SEG"
      fi
      (( 16#${SEG:16:8} < SEGMENTS_PER_LOG )) || fail "WAL segment index out of range: $SEG"
      PREV="$SEG"
    done < <(printf '%s\n' "${SEGMENTS[@]}" | LC_ALL=C sort -u | sed '/^$/d')
    [[ "$BEGUN" -eq 1 ]] \
      || fail "WAL GAP: base START segment $STARTSEG not present in staged WAL"
    log "WAL chain continuous: $STARTSEG .. $PREV"
  fi
  chmod 700 "$PGDATA" "$WALCOPY"
  docker run --rm --network none --entrypoint /bin/chown \
    -v "$PGDATA:/w/pgdata" -v "$WALCOPY:/w/wal" "$PG_IMAGE" \
    -R postgres:postgres /w/pgdata /w/wal >/dev/null || fail "chown of replay inputs failed"
  log "starting socket-only throwaway $PG_IMAGE for WAL replay (stack=${STACK:-?}) ..."
  docker run -d --name "$RUN_ID" --restart=no --network none \
    -e POSTGRES_PASSWORD="$PW" \
    -v "$PGDATA:/var/lib/postgresql/data" \
    -v "$WALCOPY:/wal:ro" \
    "$PG_IMAGE" -c archive_mode=off >/dev/null || fail "docker run failed"
  T1=$T0
  TARGET_DB="${DB:-postgres}"
  # Wait for recovery to finish (replay to tip of available WAL, or to the
  # explicit --recovery-target). A torn/missing tail segment makes Postgres
  # retry restore_command forever — the loop below times out and fails LOUDLY
  # with the tail of the recovery log instead of promoting a gapped timeline.
  # NOTE: local-socket exec as the image superuser — the restored instance
  # keeps its ORIGINAL password, which we do not know (and never ask for).
  # TARGET_DB must exist in the restored cluster (it does — same DBs as prod).
  DEADLINE=$((SECONDS + REPLAY_TIMEOUT))
  while :; do
    INREC="$(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo "?")"
    [[ "$INREC" == "f" ]] && break
    (( SECONDS < DEADLINE )) || break
    [[ "$(docker inspect --format '{{.State.Running}}' "$RUN_ID")" == "true" ]] || break
    sleep 2
  done
  if [[ "$INREC" != "f" ]]; then
    log "ERROR: recovery log tail (why replay is stuck):"
    docker logs "$RUN_ID" 2>&1 | grep -a -E 'FATAL|ERROR|WARNING|restore|recovery|WAL|target' | tail -20 || true
    fail "replay did not complete (timeout ${REPLAY_TIMEOUT}s, PostgreSQL failure, or unreachable target)"
  fi
  if [[ "$RECOVERY_KIND" == "latest" && -n "$WALDIR" ]]; then
    printf -v TIP_LSN '%X/%08X' "$((16#${PREV:8:8}))" "$((16#${PREV:16:8} * SEG_BYTES))"
    AT_TIP="$(docker exec "$RUN_ID" psql -U "$DBUSER" -d "$TARGET_DB" -tAc \
      "SELECT pg_last_wal_replay_lsn() >= '$TIP_LSN'::pg_lsn;")"
    [[ "$AT_TIP" == "t" ]] || fail "replay ended before the last staged WAL segment ($PREV)"
    log "replay reached the last staged WAL segment: $PREV"
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
