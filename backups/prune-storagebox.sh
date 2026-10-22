#!/usr/bin/env bash
# Prune off-host Storagebox dump copies — 30d retention to mirror S3 lifecycle.
#
# S3 enforces retention via bucket lifecycle (see s3-lifecycle.example.json:
# coolify/postgres/ 30d, coolify/obs/ 14d). The Storagebox off-host copies
# (~/storagebox/backups/<area>/YYYY/MM/DD/*.{dump,dump.gz}) have no lifecycle
# engine, so this script is the retention enforcer for that leg.
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
for area in $AREAS; do
  dir="$STORAGEBOX_ROOT/$area"
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' f; do
    TOTAL=$((TOTAL + 1))
    if [[ "$APPLY" == "1" ]]; then
      echo "DELETE $f"
      rm -f "$f"
    else
      echo "WOULD-DELETE $f"
    fi
  done < <(find "$dir" -type f \( -name '*.dump' -o -name '*.dump.gz' \) -mtime "+$KEEP_DAYS" -print0 2>/dev/null)
done

if [[ "$APPLY" == "1" ]]; then
  # Drop date dirs left empty by the prune (YYYY/MM/DD husks only).
  find "$STORAGEBOX_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  echo "PRUNE_APPLIED keep_days=$KEEP_DAYS deleted=$TOTAL"
else
  echo "DRY_RUN keep_days=$KEEP_DAYS candidates=$TOTAL (re-run with --apply to delete)"
fi
