#!/usr/bin/env bash
# Daily off-Contabo Storagebox mirror of S3 backup prefixes + edge TLS + prune.
#
# Runs ON the Hetzner operator box (has the Storagebox mount at
# ~/storagebox + AWS read creds). Cron: backups/storagebox-sync.cron
# (`30 4 * * *` Europe/Berlin — after the contabo 02:30 pg dumps and
# the 03:30 control-plane bundles).
#
# Steps (each logged; exit 0 only if ALL succeed):
#   1) aws s3 sync  s3://<bucket>/coolify/postgres/      -> $STORAGEBOX_ROOT/s3/coolify/postgres/
#   2) aws s3 sync  s3://<bucket>/coolify/control-plane/ -> $STORAGEBOX_ROOT/s3/coolify/control-plane/
#   3) edge/acme-backup.sh  (fetch + GPG-encrypt Traefik acme.json, both hosts)
#   4) prune-storagebox.sh --apply (legacy areas + s3 mirror + edge-tls, 30d)
#
# Non-destructive by design: sync uses NO --delete (stale mirror copies age
# out via step 4); nothing is ever deleted from S3 or Contabo here.
# Freshness marker: $STORAGEBOX_ROOT/s3/.last-sync (UTC) on success.
#
# Secrets: NEVER in git. AWS creds come from the standard chain
# (AWS_PROFILE, default storagebox-mirror-reader — the dedicated
# READ-ONLY IAM principal scoped to s3://<bucket>/coolify/* Get/List only;
# see backups/storagebox-mirror-reader-iam.tf). main-temp is FORBIDDEN here
# (Hub session rules: no static main-account key for this job).
# the acme GPG passphrase lives in ~/.secrets/ (see edge/acme-backup.sh).
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-${STORAGEBOX_AWS_PROFILE:-storagebox-mirror-reader}}"
if [[ "${AWS_PROFILE}" == "main-temp" ]]; then
  echo "ERROR: AWS_PROFILE=main-temp is forbidden for storagebox-sync (use the dedicated storagebox-mirror-reader credential)" >&2
  exit 2
fi
S3_BUCKET="${S3_BUCKET:-dtc-coolify-backups-387546586013}"
STORAGEBOX_ROOT="${STORAGEBOX_ROOT:-$HOME/storagebox/backups}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE_KEEP_DAYS="${PRUNE_KEEP_DAYS:-30}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

command -v gpg >/dev/null 2>&1 || command -v /usr/bin/gpg >/dev/null 2>&1 || fail "gpg missing"
# aws cli on the operator box is a user-local install (cron PATH is minimal),
# so resolve it explicitly instead of relying on PATH.
AWS_BIN="${AWS_BIN:-$(command -v aws 2>/dev/null || echo /home/alexey/.local/bin/aws)}"
[[ -x "$AWS_BIN" ]] || fail "aws cli missing on operator box (tried PATH and /home/alexey/.local/bin/aws)"
[[ -d "$STORAGEBOX_ROOT" ]] || fail "missing Storagebox mount: $STORAGEBOX_ROOT"

FAILED=0

s3_mirror() {
  # $1 = S3 prefix (trailing slash), $2 = local subdir under $STORAGEBOX_ROOT/s3/
  local prefix="$1" dest="$STORAGEBOX_ROOT/s3/$2"
  mkdir -p "$dest"
  log "sync start s3://${S3_BUCKET}/${prefix} -> ${dest}"
  if "$AWS_BIN" s3 sync "s3://${S3_BUCKET}/${prefix}" "$dest" --only-show-errors; then
    log "sync ok ${prefix} ($(find "$dest" -type f | wc -l) local files)"
  else
    log "ERROR: sync failed for ${prefix}"
    FAILED=1
  fi
}

s3_mirror "coolify/postgres/" "coolify/postgres"
s3_mirror "coolify/control-plane/" "coolify/control-plane"

log "edge-tls start (edge/acme-backup.sh)"
if [[ -x "$HERE/../edge/acme-backup.sh" ]]; then
  "$HERE/../edge/acme-backup.sh" || { log "ERROR: acme-backup.sh failed"; FAILED=1; }
elif [[ -x "/usr/local/sbin/acme-backup.sh" ]]; then
  /usr/local/sbin/acme-backup.sh || { log "ERROR: acme-backup.sh failed"; FAILED=1; }
else
  log "ERROR: acme-backup.sh not found (repo edge/ nor /usr/local/sbin)"
  FAILED=1
fi

log "prune start (keep ${PRUNE_KEEP_DAYS}d, apply)"
if [[ -x "$HERE/prune-storagebox.sh" ]]; then
  STORAGEBOX_ROOT="$STORAGEBOX_ROOT" "$HERE/prune-storagebox.sh" --apply --keep-days "$PRUNE_KEEP_DAYS" || { log "ERROR: prune failed"; FAILED=1; }
elif [[ -x "/usr/local/sbin/prune-storagebox.sh" ]]; then
  STORAGEBOX_ROOT="$STORAGEBOX_ROOT" /usr/local/sbin/prune-storagebox.sh --apply --keep-days "$PRUNE_KEEP_DAYS" || { log "ERROR: prune failed"; FAILED=1; }
else
  log "ERROR: prune-storagebox.sh not found"
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  fail "one or more mirror steps failed"
fi

# PII restriction (non-destructive): mirror + edge copies land with the
# download umask — tighten the whole off-host backup tree to 600 files /
# 700 dirs every run so a umask change or tool default can never leave
# dumps world-readable. Owner-only on a single-user box; git checkouts
# under worktrees/ keep working for the owner.
chmod 700 "$STORAGEBOX_ROOT" 2>/dev/null || true
find "$STORAGEBOX_ROOT" -type d -exec chmod 700 {} + 2>/dev/null || true
find "$STORAGEBOX_ROOT" -type f -exec chmod 600 {} + 2>/dev/null || true

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STORAGEBOX_ROOT/s3/.last-sync"
log "ALL_DONE s3-mirror + edge-tls + prune"
