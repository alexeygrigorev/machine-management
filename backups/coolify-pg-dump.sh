#!/usr/bin/env bash
# Daily pg_dump -> S3 for Coolify Contabo Postgres (pg-shared + pg-relay).
#
# Runs ON the Coolify data node (contabo-b) as a daily cron job
# (see coolify-pg-dump.cron: 30 2 * * * Europe/Berlin).
#
# Dumps each database with pg_dump custom format (-Fc), compresses with gzip,
# and uploads to S3-compatible storage. Local copies are pruned; S3 retention
# is enforced by a bucket lifecycle rule (see s3-lifecycle.example.json).
# Optional in-script S3 pruning exists but defaults OFF (S3_PRUNE_ENABLED=0).
#
# Connection model (in order of preference):
#   1. docker exec into the Coolify Postgres containers on this host
#      (PG_SHARED_CONTAINER / PG_RELAY_CONTAINER) — no password needed.
#   2. TCP via PGHOST/PGPORT + PGPASSWORD from the env file (mode 600).
#
# Secrets: NEVER in git. All credentials come from an env file
# (/etc/coolify-pg-dump.env, root-only 600) and/or the standard AWS env vars.
# See coolify-pg-dump.env.example for the full variable list.
#
# Exit code: 0 only if every configured database dumped AND uploaded.
set -euo pipefail

ENV_FILE="${COOLIFFY_ENV_FILE:-${COOLIFY_PGDUMP_ENV_FILE:-/etc/coolify-pg-dump.env}}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

# ---- config (overridable via env file) ----
DUMP_DIR="${DUMP_DIR:-/var/backups/coolify-postgres}"
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-pg-dump.lock}"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"
STAMP="$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')"
DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"

PG_SHARED_CONTAINER="${PG_SHARED_CONTAINER:-}"
PG_RELAY_CONTAINER="${PG_RELAY_CONTAINER:-}"
PG_SHARED_DBS="${PG_SHARED_DBS:-}"     # space-separated, e.g. "cmp aishl website"
PG_RELAY_DB="${PG_RELAY_DB:-}"         # single db name on pg-relay
PGUSER_SHARED="${PGUSER_SHARED:-postgres}"
PGUSER_RELAY="${PGUSER_RELAY:-postgres}"
# TCP fallback (only used when *_CONTAINER is empty):
PGHOST_SHARED="${PGHOST_SHARED:-127.0.0.1}"
PGPORT_SHARED="${PGPORT_SHARED:-5433}"
PGHOST_RELAY="${PGHOST_RELAY:-127.0.0.1}"
PGPORT_RELAY="${PGPORT_RELAY:-5434}"

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-coolify/postgres}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"   # empty = real AWS S3
S3_PRUNE_ENABLED="${S3_PRUNE_ENABLED:-0}"
S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-30}"

[[ -n "$S3_BUCKET" ]] || fail "S3_BUCKET is not set (see coolify-pg-dump.env.example)"
[[ -n "$PG_SHARED_DBS" || -n "$PG_RELAY_DB" ]] || fail "no databases configured (PG_SHARED_DBS / PG_RELAY_DB)"

for bin in pg_dump docker gzip aws; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing required binary: $bin"
done
command -v flock >/dev/null 2>&1 || fail "missing required binary: flock"

mkdir -p "$DUMP_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another dump run is in progress (lock: $LOCK_FILE)"

FAILED=0

s3_put() {
  local src="$1" key="$2"
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --endpoint-url "$S3_ENDPOINT_URL" --only-show-errors
  else
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --only-show-errors
  fi
}

dump_one() {
  # $1=stack(pg-shared|pg-relay) $2=container(empty=TCP) $3=pguser
  # $4=host $5=port $6=dbname
  local stack="$1" container="$2" pguser="$3" host="$4" port="$5" dbname="$6"
  local outfile="${DUMP_DIR}/${dbname}-${stack}-${STAMP}.dump.gz"
  log "dump start stack=${stack} db=${dbname}"
  if [[ -n "$container" ]]; then
    docker exec "$container" pg_dump -U "$pguser" -Fc -d "$dbname" 2>"${outfile}.err" \
      | gzip -c > "$outfile" \
      || { log "ERROR: pg_dump failed stack=${stack} db=${dbname}: $(tail -3 "${outfile}.err" 2>/dev/null)"; rm -f "$outfile"; return 1; }
  else
    PGHOST="$host" PGPORT="$port" PGUSER="$pguser" pg_dump -Fc -d "$dbname" 2>"${outfile}.err" \
      | gzip -c > "$outfile" \
      || { log "ERROR: pg_dump(TCP) failed stack=${stack} db=${dbname}: $(tail -3 "${outfile}.err" 2>/dev/null)"; rm -f "$outfile"; return 1; }
  fi
  rm -f "${outfile}.err"
  local size; size="$(stat -c%s "$outfile" 2>/dev/null || stat -f%z "$outfile")"
  [[ "$size" -gt 1024 ]] || { log "ERROR: dump suspiciously small (${size}B) stack=${stack} db=${dbname}"; rm -f "$outfile"; return 1; }
  local key="${S3_PREFIX}/${stack}/${dbname}/${DAY_PATH}/${dbname}-${stack}-${STAMP}.dump.gz"
  s3_put "$outfile" "$key" || { log "ERROR: S3 upload failed stack=${stack} db=${dbname}"; return 1; }
  log "dump ok stack=${stack} db=${dbname} size=${size}B s3=s3://${S3_BUCKET}/${key}"
}

for db in $PG_SHARED_DBS; do
  dump_one "pg-shared" "$PG_SHARED_CONTAINER" "$PGUSER_SHARED" \
    "$PGHOST_SHARED" "$PGPORT_SHARED" "$db" || FAILED=1
done

if [[ -n "$PG_RELAY_DB" ]]; then
  dump_one "pg-relay" "$PG_RELAY_CONTAINER" "$PGUSER_RELAY" \
    "$PGHOST_RELAY" "$PGPORT_RELAY" "$PG_RELAY_DB" || FAILED=1
fi

# Local prune: keep newest LOCAL_KEEP_DAYS of local copies only.
find "$DUMP_DIR" -maxdepth 1 -name '*.dump.gz' -mtime "+${LOCAL_KEEP_DAYS}" -delete 2>/dev/null || true

# Optional S3 prune (default OFF — lifecycle rule is the primary retention).
if [[ "$S3_PRUNE_ENABLED" == "1" ]]; then
  log "S3 prune enabled: deleting objects older than ${S3_RETENTION_DAYS}d under s3://${S3_BUCKET}/${S3_PREFIX}/"
  CUTOFF="$(date -u -d "${S3_RETENTION_DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')"
  for stack_db in $(for db in $PG_SHARED_DBS; do echo "pg-shared/${db}"; done; [[ -n "$PG_RELAY_DB" ]] && echo "pg-relay/${PG_RELAY_DB}"); do
    if [[ -n "$S3_ENDPOINT_URL" ]]; then
      EP=(--endpoint-url "$S3_ENDPOINT_URL")
    else
      EP=()
    fi
    aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/${stack_db}/" "${EP[@]}" \
      --query "Contents[?LastModified<='${CUTOFF}'].Key" --output text 2>/dev/null \
      | tr '\t' '\n' | { grep -v '^None$' || true; } | while read -r key; do
        [[ -n "$key" ]] || continue
        log "S3 prune: deleting s3://${S3_BUCKET}/${key}"
        aws s3 rm "s3://${S3_BUCKET}/${key}" "${EP[@]}" --only-show-errors || log "WARN: failed to delete ${key}"
      done
  done
fi

if [[ "$FAILED" -ne 0 ]]; then
  fail "one or more dumps/uploads failed"
fi
log "ALL_DONE"
