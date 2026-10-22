#!/usr/bin/env bash
# Weekly pg_basebackup -> S3 for Coolify Contabo Postgres (pg-shared + pg-relay).
#
# Companion to coolify-pg-dump.sh (daily logical dumps). A base backup + WAL
# archive (see coolify-wal-archive.sh) is what makes "replay everything onto a
# fresh DB" possible: restore the base, replay WAL segments to tip (PITR).
#
# Runs ON the Coolify data node (contabo-b). See coolify-pg-basebackup.cron
# (weekly Sun 03:00 Europe/Berlin). Reads the SAME env file as the dump script
# (/etc/coolify-pg-dump.env) so operators configure containers/S3 once.
#
# Base method: pg_basebackup -Ft -z -X stream (needs a replication-capable
# role; Coolify's pgadmin superuser qualifies; max_wal_senders=10 already).
# No Postgres restart required for the backup itself. WAL archiving
# (archive_mode=on) DOES need one restart per instance — staged separately
# by coolify-wal-enable.sh during an operator window, never by this script.
#
# Secrets: NEVER in git. All credentials come from the env file (root 600)
# and/or standard AWS env vars.
#
# Exit code: 0 only if every configured stack backed up AND uploaded.
set -euo pipefail

ENV_FILE="${COOLIFY_ENV_FILE:-${COOLIFY_PGDUMP_ENV_FILE:-/etc/coolify-pg-dump.env}}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

# ---- config (overridable via env file) ----
BASE_DIR="${BASE_DIR:-/var/backups/coolify-postgres-base}"
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-pg-basebackup.lock}"
LOCAL_KEEP_COUNT="${LOCAL_KEEP_COUNT:-2}"   # keep newest N local bases per stack
STAMP="$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')"
DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"

PG_SHARED_CONTAINER="${PG_SHARED_CONTAINER:-}"
PG_RELAY_CONTAINER="${PG_RELAY_CONTAINER:-}"
PGUSER_SHARED="${PGUSER_SHARED:-pgadmin}"
PGUSER_RELAY="${PGUSER_RELAY:-pgadmin}"
# TCP fallback (only used when *_CONTAINER is empty):
PGHOST_SHARED="${PGHOST_SHARED:-127.0.0.1}"
PGPORT_SHARED="${PGPORT_SHARED:-5433}"
PGHOST_RELAY="${PGHOST_RELAY:-127.0.0.1}"
PGPORT_RELAY="${PGPORT_RELAY:-5434}"

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-coolify/postgres}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"   # empty = real AWS S3

[[ -n "$S3_BUCKET" ]] || fail "S3_BUCKET is not set (see coolify-pg-dump.env.example)"
[[ -n "$PG_SHARED_CONTAINER" || -n "$PG_RELAY_CONTAINER" ]] || fail "no stacks configured (PG_SHARED_CONTAINER / PG_RELAY_CONTAINER)"

for bin in docker aws flock; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing required binary on host: $bin"
done

if { [[ -n "$PG_SHARED_CONTAINER" ]] || [[ -n "$PG_RELAY_CONTAINER" ]]; } && ! command -v pg_basebackup >/dev/null 2>&1; then
  # pg_basebackup runs INSIDE the container via docker exec, so a host binary
  # is only needed for the TCP fallback path.
  :
fi
if { [[ -z "$PG_SHARED_CONTAINER" ]] || [[ -z "$PG_RELAY_CONTAINER" ]]; } && ! command -v pg_basebackup >/dev/null 2>&1; then
  fail "missing required binary on host for TCP basebackup: pg_basebackup (apt install postgresql-client)"
fi

mkdir -p "$BASE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another basebackup run is in progress (lock: $LOCK_FILE)"

FAILED=0

s3_put() {
  local src="$1" key="$2"
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --endpoint-url "$S3_ENDPOINT_URL" --only-show-errors
  else
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --only-show-errors
  fi
}

base_one() {
  # $1=stack $2=container(empty=TCP) $3=pguser $4=host $5=port
  local stack="$1" container="$2" pguser="$3" host="$4" port="$5"
  local outfile="${BASE_DIR}/${stack}-base-${STAMP}.tar.gz"
  log "basebackup start stack=${stack}"
  # NOTE: pg_basebackup -X stream cannot write tar to stdout, so stage
  # inside the container (or a host temp dir for TCP), then stream out.
  if [[ -n "$container" ]]; then
    local stage="/tmp/bb-${STAMP}"
    docker exec "$container" sh -c 'set -e; rm -rf '"$stage"'; pg_basebackup -U '"$pguser"' -D '"$stage"' -Ft -z -X stream -c fast; ls '"$stage"'/' \
      > "${outfile}.manifest" 2>"${outfile}.err" \
      || { log "ERROR: pg_basebackup failed stack=${stack}: $(tail -3 "${outfile}.err" 2>/dev/null)"; rm -f "$outfile" "${outfile}.manifest"; return 1; }
    # -Ft -X stream writes base.tar.gz AND pg_wal.tar.gz (the WAL streaming
    # window). Both are needed for replay: fetch each member separately.
    for member in base.tar.gz pg_wal.tar.gz; do
      grep -qx "$member" "${outfile}.manifest" || continue
      docker exec "$container" cat "${stage}/${member}" > "${BASE_DIR}/${stack}-${member%.tar.gz}-${STAMP}.tar.gz" 2>>"${outfile}.err" \
        || { log "ERROR: fetching ${member} failed stack=${stack}"; rm -f "$outfile"; return 1; }
    done
    rm -f "${outfile}.manifest"
    docker exec "$container" rm -rf "$stage" 2>/dev/null || true
    outfile="${BASE_DIR}/${stack}-base-${STAMP}.tar.gz"
  else
    local tstage; tstage="$(mktemp -d)"
    PGHOST="$host" PGPORT="$port" PGUSER="$pguser" pg_basebackup -D "$tstage" -Ft -z -X stream -c fast 2>"${outfile}.err" \
      || { log "ERROR: pg_basebackup(TCP) failed stack=${stack}: $(tail -3 "${outfile}.err" 2>/dev/null)"; rm -rf "$tstage"; rm -f "$outfile"; return 1; }
    mv "$tstage"/base.tar.gz "${BASE_DIR}/${stack}-base-${STAMP}.tar.gz"
    [[ -f "$tstage"/pg_wal.tar.gz ]] && mv "$tstage"/pg_wal.tar.gz "${BASE_DIR}/${stack}-pg_wal-${STAMP}.tar.gz"
    rm -rf "$tstage"
    outfile="${BASE_DIR}/${stack}-base-${STAMP}.tar.gz"
  fi
  rm -f "${outfile}.err"
  local size; size="$(stat -c%s "$outfile" 2>/dev/null || stat -f%z "$outfile")"
  [[ "$size" -gt 1024 ]] || { log "ERROR: base suspiciously small (${size}B) stack=${stack}"; rm -f "$outfile"; return 1; }
  local key="${S3_PREFIX}/${stack}/base/${DAY_PATH}/${stack}-base-${STAMP}.tar.gz"
  s3_put "$outfile" "$key" || { log "ERROR: S3 upload failed stack=${stack}"; return 1; }
  log "basebackup ok stack=${stack} size=${size}B s3=s3://${S3_BUCKET}/${key}"
  # Companion WAL-stream member (same backup window; REQUIRED for replay).
  local walstream="${BASE_DIR}/${stack}-pg_wal-${STAMP}.tar.gz"
  if [[ -f "$walstream" ]]; then
    local wkey="${S3_PREFIX}/${stack}/base/${DAY_PATH}/${stack}-pg_wal-${STAMP}.tar.gz"
    s3_put "$walstream" "$wkey" || { log "ERROR: S3 upload failed stack=${stack} (pg_wal member)"; return 1; }
    log "basebackup wal-window ok stack=${stack} s3=s3://${S3_BUCKET}/${wkey}"
  else
    log "WARN: no pg_wal.tar.gz member for stack=${stack} — replay needs it (check -X stream)"
  fi
  # Local prune: keep newest LOCAL_KEEP_COUNT bases per stack only.
  # shellcheck disable=SC2012
  ls -t "${BASE_DIR}/${stack}-base-"*.tar.gz 2>/dev/null | tail -n "+$((LOCAL_KEEP_COUNT + 1))" | xargs -r rm -f
  # shellcheck disable=SC2012
  ls -t "${BASE_DIR}/${stack}-pg_wal-"*.tar.gz 2>/dev/null | tail -n "+$((LOCAL_KEEP_COUNT + 1))" | xargs -r rm -f
}

if [[ -n "$PG_SHARED_CONTAINER" || -n "$PGHOST_SHARED" ]]; then
  base_one "pg-shared" "$PG_SHARED_CONTAINER" "$PGUSER_SHARED" "$PGHOST_SHARED" "$PGPORT_SHARED" || FAILED=1
fi
if [[ -n "$PG_RELAY_CONTAINER" || -n "$PGHOST_RELAY" ]]; then
  base_one "pg-relay" "$PG_RELAY_CONTAINER" "$PGUSER_RELAY" "$PGHOST_RELAY" "$PGPORT_RELAY" || FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  fail "one or more base backups/uploads failed"
fi
log "ALL_DONE"
