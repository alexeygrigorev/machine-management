#!/usr/bin/env bash
# Exercise the production freshness function without running other probes or mail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Functions are loaded only; the production script entrypoint never runs.
# shellcheck disable=SC1090
source <(sed -n '/^check_wal_freshness() {/,/^}/p' "$ROOT/monitors/coolify-healthcheck.sh")
log() { printf '%s\n' "$*"; }
send_alert() { printf 'ALERT %s %s\n' "$1" "$3"; }
mark_ok() { printf 'HEALTHY %s\n' "$1"; }
export WAL_STATE_DIR="$TMP"
WAL_STACKS='pg-shared pg-relay'
export WAL_STALE_SECONDS=1200
for value in '' '   ' yesterday '2026-99-28T02:55:04Z'; do
  printf '%s\n' "$value" > "$TMP/last-success-pg-shared"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-relay"
  FAILED=0
  check_wal_freshness > "$TMP/log"
  [[ "$FAILED" == 1 ]]
  grep -Eq 'invalid|unparseable' "$TMP/log"
  grep -q 'HEALTHY wal-pg-relay' "$TMP/log"
  ! grep -q 'age=.*last=$' "$TMP/log"
done
echo 'PASS empty, whitespace, relative and impossible dates fail closed; relay still checked'
for stack in $WAL_STACKS; do date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-$stack"; done
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 0 ]]
grep -q 'HEALTHY wal-pg-shared' "$TMP/log"
echo 'PASS fresh timestamps healthy for both stacks'
date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' > "$TMP/last-success-pg-shared"
FAILED=0
check_wal_freshness > "$TMP/log"
[[ "$FAILED" == 1 ]]
grep -q 'ALERT wal-pg-shared WAL archive stale' "$TMP/log"
echo 'PASS genuinely stale timestamps still alert'
