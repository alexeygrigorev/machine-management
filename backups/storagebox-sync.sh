#!/usr/bin/env bash
# Daily off-Contabo Storagebox mirror of Contabo backups + edge TLS + prune.
#
# Runs ON the Hetzner operator box (has the Storagebox mount at
# ~/storagebox). Cron: /etc/cron.d/storagebox-backup-sync (`30 4 * * *`
# Europe/Berlin — after the contabo 02:30 pg dumps and the 03:30
# control-plane bundles).
#
# t1852u (S3 egress cut): this mirror used to download each day's new files
# back from s3://dtc-coolify-backups-387546586013 — 0.2-2 GB/day of billed
# S3 DataTransfer-Out. It now rsyncs the same content directly from the
# Contabo origin boxes over SSH. Contabo's upload jobs keep feeding the S3
# leg unchanged, so both backup legs still exist with zero S3 egress from
# the mirror. Sources, mapped into the same tree the S3 keys used:
#   contabo-b:/var/backups/coolify-postgres/*.dump.gz        (daily dumps)
#     -> coolify/postgres/<stack>/<db>/<YYYY>/<MM>/<DD>/<file>
#   contabo-b:/var/backups/coolify-postgres-base/*.tar.gz    (weekly basebackup)
#     -> coolify/postgres/<stack>/base/<file>
#   contabo-b:/var/backups/coolify-wal-outbox/coolify/postgres/
#     (nested; fed per-minute by coolify-wal-shipper.sh's outbox copy)
#     -> coolify/postgres/            (direct rsync)
#   contabo-{a,b}:/var/backups/coolify-cp/                   (control-plane)
#     -> coolify/control-plane/<host-id>/<YYYY>/<MM>/<DD>/<file>
#
# Steps (each logged; exit 0 only if ALL succeed):
#   1) dumps + basebackup + WAL outbox from contabo-b (WAL age-checked)
#   2) control-plane bundles from contabo-a and contabo-b
#   3) prune the 3-day WAL outbox on contabo-b (S3 leg retains 30d)
#   4) edge/acme-backup.sh  (fetch + GPG-encrypt Traefik acme.json, both hosts)
#   5) prune-storagebox.sh --apply (legacy areas + mirror + edge-tls, 30d)
#
# Non-destructive by design: nothing is ever deleted from S3 or Contabo
# backups here; the outbox prune only drops already-mirrored segments older
# than 3 days. Freshness marker: $STORAGEBOX_ROOT/s3/.last-sync (UTC).
#
# Secrets: NEVER in git. No AWS credentials are used any more (the S3 leg is
# fed by the Contabo upload jobs; storagebox-mirror-reader remains on the
# box only as a break-glass read credential). The acme GPG passphrase lives
# in ~/.secrets/ (see edge/acme-backup.sh).
set -euo pipefail

STORAGEBOX_ROOT="${STORAGEBOX_ROOT:-$HOME/storagebox/backups}"
STAGING_ROOT="${STAGING_ROOT:-$HOME/.local/state/storagebox-sync}"
CP_A_HOST="${CP_A_HOST:-contabo-a}"
CP_B_HOST="${CP_B_HOST:-contabo-b}"
CP_A_HOST_ID="${CP_A_HOST_ID:-contabo-a-163}"
CP_B_HOST_ID="${CP_B_HOST_ID:-contabo-b-141}"
OUTBOX_KEEP_DAYS="${OUTBOX_KEEP_DAYS:-3}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

[[ -d "$STORAGEBOX_ROOT" ]] || fail "missing Storagebox mount: $STORAGEBOX_ROOT"
command -v rsync >/dev/null 2>&1 || fail "rsync missing on operator box"
mkdir -p "$STAGING_ROOT"

FAILED=0

rsync_into() {
  # $1 = rsync source (host:/path/), $2 = dest dir under $STORAGEBOX_ROOT/s3/, $3 = label
  local src="$1" dest="$STORAGEBOX_ROOT/s3/$2" label="$3"
  mkdir -p "$dest"
  log "rsync start ${src} -> ${dest}"
  if rsync -a --timeout=900 "$src" "$dest/"; then
    log "rsync ok ${label} ($(find "$dest" -type f | wc -l) local files)"
  else
    log "ERROR: rsync failed for ${label}"
    FAILED=1
  fi
}

# Map flat Contabo filenames into the S3-key-like tree, skipping identical
# copies already on the Storagebox (re-runs and overlap days are no-ops).
map_flat() { # $1 = staging dir, $2 = mode (dump|base|cp), $3 = cp host id
  local stage="$1" mode="$2" host_id="${3:-}" f base dest_dir datepart
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$mode" in
      dump)
        if [[ "$base" =~ ^(.+)-(pg-(shared|relay))-([0-9]{4})([0-9]{2})([0-9]{2})T[0-9]{4,6}[+-][0-9]{4}\.dump(\.gz)?$ ]]; then
          dest_dir="coolify/postgres/${BASH_REMATCH[2]}/${BASH_REMATCH[1]}/${BASH_REMATCH[4]}/${BASH_REMATCH[5]}/${BASH_REMATCH[6]}"
        else
          log "ERROR: unmatched dump filename: $base"; FAILED=1; continue
        fi
        ;;
      base)
        if [[ "$base" =~ ^(pg-(shared|relay))-(base|pg_wal)-([0-9]{4})([0-9]{2})([0-9]{2})T[0-9]{4,6}[+-][0-9]{4}\.tar\.gz$ ]]; then
          dest_dir="coolify/postgres/${BASH_REMATCH[1]}/base/${BASH_REMATCH[4]}/${BASH_REMATCH[5]}/${BASH_REMATCH[6]}"
        else
          log "ERROR: unmatched basebackup filename: $base"; FAILED=1; continue
        fi
        ;;
      cp)
        case "$base" in
          *.dump.gz|*.tar.gz.gpg|*.json)
            datepart="$(grep -oE '^[0-9]{8}' <<<"${base##*-${host_id}-}" || true)"
            if [[ -z "$datepart" ]]; then
              log "ERROR: unmatched control-plane filename: $base"; FAILED=1; continue
            fi
            dest_dir="coolify/control-plane/${host_id}/${datepart:0:4}/${datepart:4:2}/${datepart:6:2}"
            ;;
          *) continue ;;  # local logs etc. were never part of the S3 set
        esac
        ;;
    esac
    mkdir -p "$STORAGEBOX_ROOT/s3/$dest_dir"
    if ! cmp -s "$f" "$STORAGEBOX_ROOT/s3/$dest_dir/$base"; then
      install -m 600 "$f" "$STORAGEBOX_ROOT/s3/$dest_dir/$base" \
        || { log "ERROR: install failed: $base"; FAILED=1; }
    fi
  done < <(find "$stage" -type f -print0)
}

log "mirror start (contabo-direct, t1852u)"

# Flat staging areas (persistent so daily rsyncs are delta-efficient); files
# older than 8 days are pruned after mapping. The basebackup set is ~550 MB
# and only grows weekly, so re-pulling it fresh every day would be wasteful.
stage_dir() { local d="$STAGING_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# 1a) daily pg dumps (flat on contabo-b) -> staging -> nested tree
DUMPS_STAGE="$(stage_dir dumps)"
if rsync -a --timeout=900 --include='*.dump.gz' --include='*/' --exclude='*' \
    "${CP_B_HOST}:/var/backups/coolify-postgres/" "$DUMPS_STAGE/"; then
  log "rsync ok dumps ($(find "$DUMPS_STAGE" -type f | wc -l) staged)"
else
  log "ERROR: rsync failed for dumps (contabo-b)"
  FAILED=1
fi
map_flat "$DUMPS_STAGE" dump

# 1b) weekly pg_basebackup tarballs (flat) -> staging -> <stack>/base/<date>/
BASE_STAGE="$(stage_dir base)"
if rsync -a --timeout=900 --include='*.tar.gz' --include='*/' --exclude='*' \
    "${CP_B_HOST}:/var/backups/coolify-postgres-base/" "$BASE_STAGE/"; then
  log "rsync ok basebackup ($(find "$BASE_STAGE" -type f | wc -l) staged)"
else
  log "ERROR: rsync failed for basebackup (contabo-b)"
  FAILED=1
fi
map_flat "$BASE_STAGE" base

# 1c) WAL outbox (already nested, fed by the per-minute shipper outbox copy)
rsync_into "${CP_B_HOST}:/var/backups/coolify-wal-outbox/coolify/postgres/" \
  "coolify/postgres" "wal-outbox"
# Freshness check: warn when the newest mirrored WAL segment is >36h old
# (S3 leg stays authoritative; the shipper-side healthcheck pages first).
newest_wal="$(find "$STORAGEBOX_ROOT/s3/coolify/postgres" -path '*/wal/*' -type f -name '*.gz' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || true)"
if [[ -z "$newest_wal" ]]; then
  log "WARN: no WAL segments mirrored yet (outbox empty?)"
elif (( $(printf '%.0f' "$newest_wal") < $(date -d '36 hours ago' +%s) )); then
  log "WARN: newest mirrored WAL segment is older than 36h — check the shipper outbox on contabo-b"
fi

# 2) control-plane bundles (flat on each host) -> staging -> nested tree
for spec in "${CP_A_HOST}:${CP_A_HOST_ID}" "${CP_B_HOST}:${CP_B_HOST_ID}"; do
  host="${spec%%:*}" host_id="${spec##*:}"
  CP_STAGE="$(stage_dir "cp-$host_id")"
  if rsync -a --timeout=900 --include='*.dump.gz' --include='*.tar.gz.gpg' --include='*.json' \
      --include='*/' --exclude='*' "${host}:/var/backups/coolify-cp/" "$CP_STAGE/"; then
    log "rsync ok control-plane ${host_id} ($(find "$CP_STAGE" -type f | wc -l) staged)"
  else
    log "ERROR: rsync failed for control-plane ${host_id}"
    FAILED=1
  fi
  map_flat "$CP_STAGE" cp "$host_id"
done

# Bound the staging areas (the real retention lives on Storagebox + S3).
find "$STAGING_ROOT/dumps" "$STAGING_ROOT/base" "$STAGING_ROOT"/cp-* \
  -type f -mtime +8 -delete 2>/dev/null || true

# 3) prune the WAL outbox on contabo-b (root-owned; keep a 3-day tail so a
# down mirror can catch up ~2 days; S3 retains 30 days per bucket lifecycle)
log "contabo outbox prune start (keep ${OUTBOX_KEEP_DAYS}d)"
if ssh -o BatchMode=yes "$CP_B_HOST" \
    "sudo -n find /var/backups/coolify-wal-outbox -type f -mtime +${OUTBOX_KEEP_DAYS} -delete \
     && sudo -n find /var/backups/coolify-wal-outbox -mindepth 1 -type d -empty -delete"; then
  log "contabo outbox prune ok"
else
  log "ERROR: contabo outbox prune failed"
  FAILED=1
fi

log "edge-tls start (edge/acme-backup.sh)"
if [[ -x "/usr/local/sbin/acme-backup.sh" ]]; then
  /usr/local/sbin/acme-backup.sh || { log "ERROR: acme-backup.sh failed"; FAILED=1; }
else
  log "ERROR: acme-backup.sh not found at /usr/local/sbin"
  FAILED=1
fi

log "prune start (keep 30d, apply)"
if [[ -x "/usr/local/sbin/prune-storagebox.sh" ]]; then
  STORAGEBOX_ROOT="$STORAGEBOX_ROOT" /usr/local/sbin/prune-storagebox.sh --apply --keep-days 30 \
    || { log "ERROR: prune failed"; FAILED=1; }
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
log "ALL_DONE contabo-direct mirror + edge-tls + prune"
