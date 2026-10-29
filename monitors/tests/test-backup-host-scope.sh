#!/usr/bin/env bash
# Host selection, missing-path paging, and retirement/retry of wrong-host FAILs.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/coolify-healthcheck.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hostname" <<'STUB'
#!/usr/bin/env bash
echo "$TEST_HOST"
STUB
cat > "$TMP/bin/msmtp" <<'STUB'
#!/usr/bin/env bash
cat >> "$TEST_MAIL"
[[ "${TEST_MAIL_FAIL:-0}" == 0 ]]
STUB
cp "$TMP/bin/msmtp" "$TMP/bin/sendmail"
chmod +x "$TMP/bin/"*
run() {
  local host="$1" state="$2" skip="$3"
  mkdir -p "$TMP/$state"
  env -u SKIP_BACKUP_CHECKS PATH="$TMP/bin:$PATH" TEST_HOST="$host" \
    TEST_MAIL="$TMP/mail" TEST_MAIL_FAIL="${TEST_MAIL_FAIL:-0}" \
    COOLIFY_HEALTHCHECK_ENV_FILE="$TMP/env" STATE_DIR="$TMP/$state" LOCK_FILE="$TMP/lock" \
    DUMP_DIR="$TMP/missing-dumps" WAL_SHIPPER_STATE_DIR="$TMP/missing-wal" \
    EXPECT_DBS=missing WAL_STACKS=pg-shared WAL_IDLE_VERIFY=0 \
    SKIP_PG_SHARED=1 SKIP_PG_RELAY=1 SKIP_DISK_CHECK=1 SKIP_CREATED_CHECK=1 \
    PG_SHARED_CONTAINER=unused PG_RELAY_CONTAINER=unused \
    APP_URLS= CONTENT_CHECKS= LATENCY_PROBES= LATENCY_PUSH_ENABLED=0 \
    ALERT_TO=test@invalid DRILL_MODE=1 DIGEST_SCRIPT="$TMP/no-digest" \
    bash -c '[[ "$1" == unset ]] || export SKIP_BACKUP_CHECKS="$1"; exec bash "$2"' _ "$skip" "$SCRIPT" > "$TMP/log" 2>&1
}
run RMTHZ operator unset
! grep -q 'check=dump-\|check=wal-' "$TMP/log"
test ! -f "$TMP/mail"
echo 'PASS RMTHZ skips absent local paths without mail'
for host in vmd210005 contabo-b; do
  if run "$host" data unset; then echo 'FAIL missing backups passed'; exit 1; fi
  grep -q 'FAIL check=dump-missing' "$TMP/log"
  grep -q 'FAIL check=wal-pg-shared' "$TMP/log"
done
echo 'PASS data host still alerts when both directories disappear'
rm -f "$TMP/mail"
if run RMTHZ drill 0; then echo 'FAIL missing-path drill passed'; exit 1; fi
grep -q 'Subject: .* FAIL (dump-missing)' "$TMP/mail"
grep -q 'Subject: .* FAIL (wal-pg-shared)' "$TMP/mail"
echo 'PASS explicit missing-path drill alerts through captured MTA'
# Reuse actual FAIL state created by the dry run; failed recovery must retry.
: > "$TMP/mail"
if TEST_MAIL_FAIL=1 run RMTHZ drill unset; then echo 'FAIL mail failure passed'; exit 1; fi
grep -q '^STATUS=FAIL$' "$TMP/drill/dump-missing.state"
run RMTHZ drill unset
grep -q 'Subject: .* RECOVERED (dump-missing)' "$TMP/mail"
grep -q 'Local backup check retired on RMTHZ' "$TMP/mail"
grep -q '^STATUS=OK$' "$TMP/drill/dump-missing.state"
grep -q '^STATUS=OK$' "$TMP/drill/wal-pg-shared.state"
: > "$TMP/mail"
run RMTHZ drill unset
test ! -s "$TMP/mail"
echo 'PASS wrong-host retirement sends recovery, retries failed delivery, then stays quiet'
run vmd210005 explicit-skip 1
grep -q 'SKIP_BACKUP_CHECKS=1' "$TMP/log"
echo 'PASS explicit skip remains supported'
