#!/usr/bin/env bash
# Verify the GC report states its effective mode. This exercises dry-run only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/rmthz-disk-gc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/reports"

OUTPUT="$TMP/output.txt"
RMTHZ_GC_ALLOW_HOST=1 \
RMTHZ_GC_STATE_DIR="$TMP/state" \
RMTHZ_GC_REPORT_DIR="$TMP/reports" \
"$SCRIPT" --dry-run --trigger manual > "$OUTPUT"

REPORT="$(find "$TMP/reports" -maxdepth 1 -type f -name 'rmthz-disk-gc-*.txt' -print -quit)"
[[ -n "$REPORT" ]]
grep -Eq '^run=.* mode=dry-run trigger=manual ' "$OUTPUT"
grep -Eq '^RMTHZ disk GC mode=dry-run [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$REPORT"
grep -q '^Trigger: manual$' "$REPORT"
echo 'PASS: dry-run stdout and report both record the effective mode'
