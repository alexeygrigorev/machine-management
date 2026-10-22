#!/usr/bin/env bash
# WAL segment archiver for Coolify Contabo Postgres -> S3.
#
# Installed as the Postgres `archive_command` on the data node (contabo-b):
#   archive_command = '/usr/local/sbin/coolify-wal-archive.sh pg-shared %p %f'
# (one stack name per instance: pg-shared | pg-relay).
#
# Each completed 16MB WAL segment is gzipped and uploaded to:
#   s3://<S3_BUCKET>/coolify/postgres/<stack>/wal/<YYYY>/<MM>/<DD>/<filename>.gz
# Exit 0 only when the object is durably in S3 (archive_command retries
# non-zero exits, so a transient failure just retries — never report 0 early).
#
# Config: /etc/coolify-wal-archive.env (root-only 600) with S3_BUCKET,
# S3_PREFIX, S3_ENDPOINT_URL (optional), AWS credentials. Same bucket as the
# dump/base scripts (dtc-coolify-backups-387546586013); lifecycle rule keeps
# wal/ for 30 days alongside dumps.
#
# Concurrency: Postgres may invoke archive_command for several segments in
# parallel — this script uses per-segment temp files, no global lock.
set -euo pipefail

STACK="${1:-}"
SRC_PATH="${2:-}"
SEGMENT="${3:-}"

log() { printf '%s wal-archive stack=%s seg=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${STACK:-?}" "${SEGMENT:-?}" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

[[ -n "$STACK" && -n "$SRC_PATH" && -n "$SEGMENT" ]] || fail "usage: $0 <pg-shared|pg-relay> <segment-path> <segment-name>"
[[ -f "$SRC_PATH" ]] || fail "segment file missing: $SRC_PATH"
case "$STACK" in
  pg-shared|pg-relay) ;;
  *) fail "unknown stack: $STACK" ;;
esac

ENV_FILE="${COOLIFY_WAL_ENV_FILE:-/etc/coolify-wal-archive.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-coolify/postgres}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
[[ -n "$S3_BUCKET" ]] || fail "S3_BUCKET is not set in ${ENV_FILE}"

command -v aws >/dev/null 2>&1 || fail "missing binary: aws"
command -v gzip >/dev/null 2>&1 || fail "missing binary: gzip"

DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"
TMP="$(mktemp "/tmp/wal-${SEGMENT}.XXXXXX.gz")"
trap 'rm -f "$TMP"' EXIT
gzip -c "$SRC_PATH" > "$TMP"

KEY="${S3_PREFIX}/${STACK}/wal/${DAY_PATH}/${SEGMENT}.gz"
if [[ -n "$S3_ENDPOINT_URL" ]]; then
  aws s3 cp "$TMP" "s3://${S3_BUCKET}/${KEY}" --endpoint-url "$S3_ENDPOINT_URL" --only-show-errors \
    || fail "S3 upload failed: s3://${S3_BUCKET}/${KEY}"
else
  aws s3 cp "$TMP" "s3://${S3_BUCKET}/${KEY}" --only-show-errors \
    || fail "S3 upload failed: s3://${S3_BUCKET}/${KEY}"
fi

# Read-back: confirm the object exists before reporting success to Postgres.
if [[ -n "$S3_ENDPOINT_URL" ]]; then
  aws s3 ls "s3://${S3_BUCKET}/${KEY}" --endpoint-url "$S3_ENDPOINT_URL" >/dev/null \
    || fail "S3 read-back failed: s3://${S3_BUCKET}/${KEY}"
else
  aws s3 ls "s3://${S3_BUCKET}/${KEY}" >/dev/null \
    || fail "S3 read-back failed: s3://${S3_BUCKET}/${KEY}"
fi

log "archived size=$(stat -c%s "$TMP" 2>/dev/null || stat -f%z "$TMP") s3=s3://${S3_BUCKET}/${KEY}"
exit 0
