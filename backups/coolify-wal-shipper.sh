#!/usr/bin/env bash
# WAL spool shipper for Coolify Contabo Postgres -> S3.
#
# Why a shipper: the postgres:16 container has NO aws CLI (and Coolify
# manages the container without extra mounts), so `archive_command` cannot
# upload to S3 directly. Instead Postgres archives synchronously to a spool
# dir inside PGDATA (host-visible via the docker volume):
#   archive_command = 'cp %p /var/lib/postgresql/data/wal_spool/.%f.tmp && mv <spool>/.%f.tmp <spool>/%f'
# This script (host cron, every minute) gzips + uploads spooled segments to:
#   s3://<S3_BUCKET>/coolify/postgres/<stack>/wal/<YYYY>/<MM>/<DD>/<segment>.gz
# with S3 read-back before deleting the spool copy.
#
# Postgres considers a segment archived once the local spool copy succeeds,
# so a stalled shipper would lose WAL to recycling. Mitigations:
#   - wal_keep_size='1GB' backstop on primary (already set, t1037u)
#   - shipper runs every minute; each run is flock-guarded
#   - STATE_DIR/last-success-<stack> timestamps each verified upload;
#     wire into monitors/coolify-healthcheck.sh (alert if stale >15 min)
#   - ERROR lines in the log if any spool file is older than 15 min
#
# Config: /etc/coolify-wal-archive.env (root-only 600) with S3_BUCKET,
# S3_PREFIX, S3_ENDPOINT_URL (optional), AWS credentials. Same bucket as the
# dump/base scripts (dtc-coolify-backups-387546586013).
#
# Secrets: NEVER in git. All credentials come from the env file (root 600).
set -euo pipefail

ENV_FILE="${COOLIFY_WAL_ENV_FILE:-/etc/coolify-wal-archive.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

log() { printf '%s wal-shipper %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-coolify/postgres}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
[[ -n "$S3_BUCKET" ]] || fail "S3_BUCKET is not set in ${ENV_FILE}"

# t1852u (S3 egress cut): additionally stage every verified segment in a local
# outbox that mirrors the S3 key layout. The Hetzner Storagebox mirror pulls
# WAL from here over SSH instead of downloading it back from S3 (egress $).
# Best-effort: S3 stays the authoritative leg; an outbox failure is logged
# and marks the run failed but never blocks spool cleanup. Empty = disabled.
WAL_OUTBOX_DIR="${WAL_OUTBOX_DIR:-/var/backups/coolify-wal-outbox}"

for bin in docker aws gzip flock find mktemp mv; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing binary on host: $bin"
done

# Stack -> container mapping. Same containers as /etc/coolify-pg-dump.env.
# Default covers BOTH stacks (pg-relay enabled 2026-10-22 t1143u); override
# with WAL_STACKS="pg-shared" in /etc/coolify-wal-archive.env to narrow.
STACKS="${WAL_STACKS:-pg-shared pg-relay}"
declare -A CONTAINER_FOR=(
  [pg-shared]="${PG_SHARED_CONTAINER:-ekm57uezdngrrscn0aqzidr8}"
  [pg-relay]="${PG_RELAY_CONTAINER:-mqimefrti7ratmaliirnikov}"
)

STATE_DIR="${WAL_SHIPPER_STATE_DIR:-/var/lib/coolify-wal-shipper}"
mkdir -p "$STATE_DIR"
LOCK_FILE="${WAL_SHIPPER_LOCK:-/var/lock/coolify-wal-shipper.lock}"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another shipper run is in progress (lock: $LOCK_FILE)"

DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"
FAILED=0
SHIPPED=0

s3_cp_stdin() { # $1=s3url ; stdin=data
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    aws s3 cp - "$1" --endpoint-url "$S3_ENDPOINT_URL" --only-show-errors
  else
    aws s3 cp - "$1" --only-show-errors
  fi
}
s3_exists() { # $1=s3url
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    aws s3 ls "$1" --endpoint-url "$S3_ENDPOINT_URL" >/dev/null
  else
    aws s3 ls "$1" >/dev/null
  fi
}

spool_for() { # $1=container -> prints host spool path
  local ctr="$1" mnt
  mnt="$(docker inspect "$ctr" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -n "$mnt" ]] || { log "ERROR: cannot resolve PGDATA mount for container $ctr"; return 1; }
  printf '%s/wal_spool' "$mnt"
}

for STACK in $STACKS; do
  CTR="${CONTAINER_FOR[$STACK]:-}"
  [[ -n "$CTR" ]] || { log "ERROR: unknown stack $STACK"; FAILED=1; continue; }
  SPOOL="$(spool_for "$CTR")" || { FAILED=1; continue; }
  [[ -d "$SPOOL" ]] || { log "stack=$STACK no spool dir yet ($SPOOL), skipping"; continue; }

  while IFS= read -r -d '' SEG; do
    NAME="$(basename "$SEG")"
    KEY="${S3_PREFIX}/${STACK}/wal/${DAY_PATH}/${NAME}.gz"
    URL="s3://${S3_BUCKET}/${KEY}"
    if gzip -c "$SEG" | s3_cp_stdin "$URL" && s3_exists "$URL"; then
      # t1852u: outbox copy for the direct Contabo->Storagebox mirror feed
      # (same relative key as S3). Runs before spool cleanup; failure keeps
      # the S3 leg authoritative and never retains the spool copy.
      if [[ -n "$WAL_OUTBOX_DIR" ]]; then
        OUTBOX="${WAL_OUTBOX_DIR}/${KEY}"
        if ! { mkdir -p "${OUTBOX%/*}" && gzip -c "$SEG" > "${OUTBOX}.tmp" \
               && mv -f "${OUTBOX}.tmp" "$OUTBOX"; }; then
          log "ERROR: stack=$STACK seg=$NAME outbox copy failed (S3 leg OK)"
          FAILED=1
        fi
      fi
      rm -f "$SEG"
      SHIPPED=$((SHIPPED + 1))
      # Readers run concurrently. Never expose a truncated/empty timestamp:
      # GNU date -d '' treats an empty value as midnight, causing false pages.
      STATE_TMP="$(mktemp "$STATE_DIR/.last-success-$STACK.XXXXXX")"
      if ! { date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_TMP" &&
             mv -f "$STATE_TMP" "$STATE_DIR/last-success-$STACK"; }; then
        rm -f "$STATE_TMP"
        fail "stack=$STACK cannot publish last-success timestamp"
      fi
      log "stack=$STACK seg=$NAME archived s3=$URL"
    else
      log "ERROR: stack=$STACK seg=$NAME S3 upload/read-back failed, keeping spool copy"
      FAILED=1
    fi
  done < <(find "$SPOOL" -maxdepth 1 -type f ! -name '.*' -print0)

  # Stale-spool alarm: any unshipped segment older than 15 min means the
  # S3 path is broken while Postgres keeps recycling -> page via logs.
  if STALE="$(find "$SPOOL" -maxdepth 1 -type f ! -name '.*' -mmin +15 -print -quit)"; then
    [[ -n "$STALE" ]] && { log "ERROR: stack=$STACK stale spool file(s), oldest: $(basename "$STALE") — S3 uploads failing"; FAILED=1; }
  fi
done

log "done shipped=$SHIPPED failed=$FAILED"
exit "$FAILED"
