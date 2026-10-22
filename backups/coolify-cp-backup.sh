#!/usr/bin/env bash
# Nightly Coolify control-plane backup -> S3 (coolify-db + APP_KEY/.env + SSH keys).
#
# Runs ON each Coolify CP host (contabo-a / contabo-b) as a daily cron job
# (see coolify-cp-backup.cron: 30 3 * * * Europe/Berlin — offset from the
# 02:30 app-DB dumps to avoid IO contention).
#
# What it backs up:
#   1. coolify-db (Postgres 15, db=coolify user=coolify): pg_dump custom
#      format (-Fc) via `docker exec coolify-db`, gzipped.
#   2. Control-plane bundle: /data/coolify/source/.env (+ .env.production)
#      + /data/coolify/ssh/keys/* (Coolify-managed SSH private keys),
#      tarred + gzipped + gpg symmetric-encrypted (AES256) with a host-local
#      passphrase file. Decrypt needs the passphrase (operator secrets only).
#
# S3 layout (canonical):
#   s3://<S3_BUCKET>/coolify/control-plane/<host-id>/YYYY/MM/DD/coolify-db-<host-id>-<STAMP>.dump.gz
#   s3://<S3_BUCKET>/coolify/control-plane/<host-id>/YYYY/MM/DD/coolify-cp-bundle-<host-id>-<STAMP>.tar.gz.gpg
#
# Secrets: NEVER in git. S3 keys come from /etc/coolify-cp-backup.env
# (root-only 600); GPG passphrase from /etc/coolify-cp-backup.pass (600).
# See coolify-cp-backup.env.example for the full variable list.
#
# Exit code: 0 only if dump AND bundle both uploaded.
set -euo pipefail

ENV_FILE="${COOLIFY_CP_ENV_FILE:-/etc/coolify-cp-backup.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

# ---- config (overridable via env file) ----
CP_HOST_ID="${CP_HOST_ID:-unknown-host}"
DUMP_DIR="${DUMP_DIR:-/var/backups/coolify-cp}"
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-cp-backup.lock}"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"
STAMP="$(TZ=Europe/Berlin date '+%Y%m%dT%H%M%z')"
DAY_PATH="$(TZ=Europe/Berlin date '+%Y/%m/%d')"

CP_DB_CONTAINER="${CP_DB_CONTAINER:-coolify-db}"
CP_DB_USER="${CP_DB_USER:-coolify}"
CP_DB_NAME="${CP_DB_NAME:-coolify}"

COOLIFY_ENV_SRC="${COOLIFY_ENV_SRC:-/data/coolify/source/.env}"
COOLIFY_ENV_PROD="${COOLIFY_ENV_PROD:-/data/coolify/source/.env.production}"
SSH_KEYS_DIR="${SSH_KEYS_DIR:-/data/coolify/ssh/keys}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-/etc/coolify-cp-backup.pass}"

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-coolify/control-plane}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"   # empty = real AWS S3

[[ -n "$S3_BUCKET" ]] || fail "S3_BUCKET is not set (see coolify-cp-backup.env.example)"
[[ "$CP_HOST_ID" != "unknown-host" ]] || fail "CP_HOST_ID is not set (e.g. contabo-a-163)"
[[ -f "$GPG_PASSPHRASE_FILE" ]] || fail "GPG passphrase file missing: $GPG_PASSPHRASE_FILE"
[[ -f "$COOLIFY_ENV_SRC" ]] || fail "Coolify .env missing: $COOLIFY_ENV_SRC"
[[ -d "$SSH_KEYS_DIR" ]] || fail "SSH keys dir missing: $SSH_KEYS_DIR"

for bin in docker gzip aws gpg tar flock; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing required binary on host: $bin"
done
chmod 600 "$GPG_PASSPHRASE_FILE" 2>/dev/null || true

mkdir -p "$DUMP_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another CP backup run is in progress (lock: $LOCK_FILE)"

s3_put() {
  local src="$1" key="$2"
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --endpoint-url "$S3_ENDPOINT_URL" --only-show-errors
  else
    aws s3 cp "$src" "s3://${S3_BUCKET}/${key}" --only-show-errors
  fi
}

FAILED=0

# ---- 1) coolify-db dump ----
DB_OUT="${DUMP_DIR}/coolify-db-${CP_HOST_ID}-${STAMP}.dump.gz"
log "dump start coolify-db host=${CP_HOST_ID}"
if docker exec "$CP_DB_CONTAINER" pg_dump -U "$CP_DB_USER" -Fc -d "$CP_DB_NAME" 2>"${DB_OUT}.err" \
    | gzip -c > "$DB_OUT"; then
  rm -f "${DB_OUT}.err"
  DB_SIZE="$(stat -c%s "$DB_OUT" 2>/dev/null || stat -f%z "$DB_OUT")"
  if [[ "$DB_SIZE" -gt 1024 ]]; then
    DB_KEY="${S3_PREFIX}/${CP_HOST_ID}/${DAY_PATH}/coolify-db-${CP_HOST_ID}-${STAMP}.dump.gz"
    if s3_put "$DB_OUT" "$DB_KEY"; then
      log "dump ok coolify-db host=${CP_HOST_ID} size=${DB_SIZE}B s3=s3://${S3_BUCKET}/${DB_KEY}"
    else
      log "ERROR: S3 upload failed coolify-db host=${CP_HOST_ID}"; FAILED=1; rm -f "$DB_OUT"
    fi
  else
    log "ERROR: dump suspiciously small (${DB_SIZE}B) coolify-db host=${CP_HOST_ID}"; rm -f "$DB_OUT"; FAILED=1
  fi
else
  log "ERROR: pg_dump failed coolify-db host=${CP_HOST_ID}: $(tail -3 "${DB_OUT}.err" 2>/dev/null)"; rm -f "$DB_OUT"; FAILED=1
fi

# ---- 2) encrypted .env + SSH keys bundle ----
BUNDLE_PLAIN="${DUMP_DIR}/coolify-cp-bundle-${CP_HOST_ID}-${STAMP}.tar.gz"
BUNDLE_ENC="${BUNDLE_PLAIN}.gpg"
log "bundle start host=${CP_HOST_ID}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$COOLIFY_ENV_SRC" "$STAGE/coolify.env" 2>/dev/null || { log "ERROR: cannot stage $COOLIFY_ENV_SRC"; FAILED=1; }
if [[ -f "$COOLIFY_ENV_PROD" ]]; then
  cp -a "$COOLIFY_ENV_PROD" "$STAGE/coolify.env.production" 2>/dev/null || true
fi
mkdir -p "$STAGE/ssh-keys"
# Copy private keys + .pub (skip *.lock); names preserved, content encrypted at rest.
cp -a "$SSH_KEYS_DIR"/ssh_key@* "$STAGE/ssh-keys/" 2>/dev/null || true
rm -f "$STAGE"/ssh-keys/*.lock 2>/dev/null || true
KEY_COUNT="$(find "$STAGE/ssh-keys" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$KEY_COUNT" -ge 1 ]] || log "WARN: no SSH keys staged from $SSH_KEYS_DIR (bundle .env only)"
tar -czf "$BUNDLE_PLAIN" -C "$STAGE" coolify.env coolify.env.production ssh-keys 2>/dev/null \
  || tar -czf "$BUNDLE_PLAIN" -C "$STAGE" coolify.env ssh-keys \
  || { log "ERROR: tar bundle failed"; FAILED=1; }
if [[ -f "$BUNDLE_PLAIN" ]]; then
  if gpg --batch --yes --pinentry-mode loopback \
      --passphrase-file "$GPG_PASSPHRASE_FILE" \
      --symmetric --cipher-algo AES256 \
      -o "$BUNDLE_ENC" "$BUNDLE_PLAIN" 2>"${BUNDLE_ENC}.err"; then
    rm -f "$BUNDLE_PLAIN" "${BUNDLE_ENC}.err"
    ENC_SIZE="$(stat -c%s "$BUNDLE_ENC" 2>/dev/null || stat -f%z "$BUNDLE_ENC")"
    BUNDLE_KEY="${S3_PREFIX}/${CP_HOST_ID}/${DAY_PATH}/coolify-cp-bundle-${CP_HOST_ID}-${STAMP}.tar.gz.gpg"
    if s3_put "$BUNDLE_ENC" "$BUNDLE_KEY"; then
      log "bundle ok host=${CP_HOST_ID} keys=${KEY_COUNT} size=${ENC_SIZE}B s3=s3://${S3_BUCKET}/${BUNDLE_KEY}"
    else
      log "ERROR: S3 upload failed bundle host=${CP_HOST_ID}"; FAILED=1; rm -f "$BUNDLE_ENC"
    fi
  else
    log "ERROR: gpg encrypt failed: $(tail -3 "${BUNDLE_ENC}.err" 2>/dev/null)"; rm -f "$BUNDLE_PLAIN" "$BUNDLE_ENC"; FAILED=1
  fi
fi
rm -rf "$STAGE"; trap - EXIT

# Local prune: keep newest LOCAL_KEEP_DAYS of local copies only.
find "$DUMP_DIR" -maxdepth 1 \( -name '*.dump.gz' -o -name '*.tar.gz.gpg' \) -mtime "+${LOCAL_KEEP_DAYS}" -delete 2>/dev/null || true

if [[ "$FAILED" -ne 0 ]]; then
  fail "one or more CP backup steps failed"
fi
log "ALL_DONE host=${CP_HOST_ID}"
