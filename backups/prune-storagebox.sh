#!/usr/bin/env bash
# Prune off-host Storagebox dump copies — 30d retention to mirror S3 lifecycle.
#
# S3 enforces retention via bucket lifecycle (see s3-lifecycle.example.json:
# coolify/postgres/ + data/coolify/backups/ 30d, coolify/obs/ + 14d,
# coolify/control-plane/ 30d). The Storagebox off-host copies below have no
# lifecycle engine, so this script is the retention enforcer for that leg.
#
# SAFE BY DEFAULT: dry-run only lists what would be deleted.
# Delete only with --apply.
#
# Usage:
#   ./backups/prune-storagebox.sh                  # dry-run, 30d keep
#   ./backups/prune-storagebox.sh --apply          # actually delete
#   ./backups/prune-storagebox.sh --apply --keep-days 14
#   STORAGEBOX_ROOT=/mnt/other ./backups/prune-storagebox.sh --apply
#
# No secrets in git: paths only, no credentials.
set -euo pipefail

KEEP_DAYS=30
APPLY=0
STORAGEBOX_ROOT="${STORAGEBOX_ROOT:-$HOME/storagebox/backups}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --keep-days) KEEP_DAYS="${2:?}"; shift 2 ;;
    --keep-days=*) KEEP_DAYS="${1#*=}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || { echo "KEEP_DAYS must be numeric" >&2; exit 2; }
[[ -d "$STORAGEBOX_ROOT" ]] || { echo "missing dir: $STORAGEBOX_ROOT" >&2; exit 1; }

# Off-host dump areas mirroring the S3 coolify/postgres/ tree (+ RDS seeds).
AREAS="cmp-pg aisl-pg website-pg relay-pg rds-seed rds-seed-t1019u"

TOTAL=0
prune_one() {
  # $1 = dir, $2.. = -name globs (OR-ed)
  local dir="$1"; shift
  [[ -d "$dir" ]] || return 0
  local args=()
  local g
  for g in "$@"; do args+=(-o -name "$g"); done
  # strip leading -o: ("("${args[@]:1}")")
  while IFS= read -r -d '' f; do
    TOTAL=$((TOTAL + 1))
    if [[ "$APPLY" == "1" ]]; then
      echo "DELETE $f"
      rm -f "$f"
    else
      echo "WOULD-DELETE $f"
    fi
  done < <(find "$dir" -type f \( "${args[@]:1}" \) -mtime "+$KEEP_DAYS" -print0 2>/dev/null)
}

for area in $AREAS; do
  prune_one "$STORAGEBOX_ROOT/$area" '*.dump' '*.dump.gz'
done
# GPG-encrypted edge TLS snapshots (see edge/acme-backup.sh).
prune_one "$STORAGEBOX_ROOT/edge-tls" '*.json.gpg'
# S3 mirror tree maintained by storagebox-sync.sh (no --delete: age-pruned here).
if [[ -d "$STORAGEBOX_ROOT/s3" ]]; then
  # '*.gz' also covers WAL segments (*.gz) and basebackup tarballs (*.tar.gz),
  # which the S3 leg's 30d lifecycle expires too (they were never pruned here).
  prune_one "$STORAGEBOX_ROOT/s3" '*.dump.gz' '*.dump' '*.tar.gz.gpg' '*.json.gpg' '*.gz'
fi

if [[ "$APPLY" == "1" ]]; then
  # Drop date dirs left empty by the prune (YYYY/MM/DD husks only).
  find "$STORAGEBOX_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  echo "PRUNE_APPLIED keep_days=$KEEP_DAYS deleted=$TOTAL"
else
  echo "DRY_RUN keep_days=$KEEP_DAYS candidates=$TOTAL (re-run with --apply to delete)"
fi
