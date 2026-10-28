#!/usr/bin/env bash
# Exercise real shipper publication while date is still producing its output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data/wal_spool" "$TMP/state"
export TEST_ROOT="$TMP"
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
printf '%s/data\n' "$TEST_ROOT"
STUB
cat > "$TMP/bin/aws" <<'STUB'
#!/bin/bash
if [[ "$2" == cp ]]; then cat >/dev/null; fi
STUB
cat > "$TMP/bin/date" <<'STUB'
#!/bin/bash
if [[ "$*" == "-u +%Y-%m-%dT%H:%M:%SZ" && "$(readlink /proc/$$/fd/1)" == "$TEST_ROOT/state/"* ]]; then
  # A concurrent reader must still see the complete previous timestamp.
  [[ "$(cat "$TEST_ROOT/state/last-success-pg-shared")" == '2026-10-28T02:50:04Z' ]] || exit 87
  [[ "${FAIL_DATE:-0}" == 0 ]] || exit 88
  printf '2026-10-28T02:55:04Z\n'
else
  /usr/bin/date "$@"
fi
STUB
chmod +x "$TMP/bin/"*
run_shipper() {
  PATH="$TMP/bin:/usr/bin:/bin" COOLIFY_WAL_ENV_FILE="$TMP/absent" \
    S3_BUCKET=test WAL_STACKS=pg-shared WAL_SHIPPER_STATE_DIR="$TMP/state" \
    WAL_SHIPPER_LOCK="$TMP/lock" bash "$ROOT/backups/coolify-wal-shipper.sh" >"$TMP/log" 2>&1
}
printf '2026-10-28T02:50:04Z\n' > "$TMP/state/last-success-pg-shared"
printf 'test segment' > "$TMP/data/wal_spool/00000001000000060000007A"
run_shipper || { cat "$TMP/log"; exit 1; }
[[ "$(cat "$TMP/state/last-success-pg-shared")" == '2026-10-28T02:55:04Z' ]]
echo 'PASS atomic publication preserves the previous timestamp during write'
printf '2026-10-28T02:50:04Z\n' > "$TMP/state/last-success-pg-shared"
printf 'test segment' > "$TMP/data/wal_spool/00000001000000060000007B"
export FAIL_DATE=1
if run_shipper; then echo 'FAIL expected timestamp producer failure'; exit 1; fi
[[ "$(cat "$TMP/state/last-success-pg-shared")" == '2026-10-28T02:50:04Z' ]]
echo 'PASS timestamp producer failure preserves previous success'
