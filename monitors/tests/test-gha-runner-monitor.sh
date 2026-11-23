#!/usr/bin/env bash
# Offline unit tests for gha-runner-monitor.sh and gha-runner-cleanup.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_DIR="$(cd "$HERE/.." && pwd)"
MON_SCRIPT="${MON_DIR}/gha-runner-monitor.sh"
CLEANUP_SCRIPT="${MON_DIR}/gha-runner-cleanup.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label} (got='${got}', want='${want}')" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" hay="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$hay"; then
    echo "PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label} (expected substring '${needle}')" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---- syntax checks ----
bash -n "$MON_SCRIPT"
bash -n "$CLEANUP_SCRIPT"
bash -n "${MON_DIR}/install-gha-runner-monitor.sh"
bash -n "${MON_DIR}/install-gha-runner-hardening.sh"
echo "PASS: syntax checks"
PASS=$((PASS + 1))

# ---- build stub binaries for monitor tests ----
STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"

cat > "${STUB_BIN}/relay" <<'STUB'
#!/usr/bin/env bash
# Record every sent mail into STUB_MAIL_LOG
to="" subj=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) to="$2"; shift 2 ;;
    --subject) subj="$2"; shift 2 ;;
    *) shift ;;
  esac
done
body="$(cat)"
printf 'TO=%s|SUBJECT=%s|BODY=%s\n' "$to" "$subj" "$(echo "$body" | tr '\n' ' ')" >> "${STUB_MAIL_LOG}"
exit "${STUB_RELAY_RC:-0}"
STUB
chmod +x "${STUB_BIN}/relay"

cat > "${STUB_BIN}/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 100000 50000 50000 ${STUB_DISK_PCT:-40}% /"
STUB
chmod +x "${STUB_BIN}/df"

cat > "${STUB_BIN}/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-unit-files)
    echo "actions.runner.Org-repo.hetzner-r1.service enabled enabled"
    ;;
  show)
    echo "ActiveState=${STUB_UNIT_ACTIVE:-active}"
    echo "SubState=${STUB_UNIT_SUB:-running}"
    echo "UnitFileState=enabled"
    ;;
  start)
    echo "STARTED $2" >> "${STUB_RECOVER_LOG}"
    exit 0
    ;;
esac
STUB
chmod +x "${STUB_BIN}/systemctl"

cat > "${STUB_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && shift
exec "$@"
STUB
chmod +x "${STUB_BIN}/sudo"

cat > "${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
# $1=api $2=endpoint
if [[ "${STUB_GH_FAIL:-0}" == "1" ]]; then
  echo "HTTP 401 Unauthorized" >&2
  exit 1
fi
case "$2" in
  *"/actions/runners"*)
    printf '{"runners":[{"name":"hetzner-r1","status":"%s","busy":false}]}\n' "${STUB_RUNNER_STATUS:-online}"
    ;;
  *"/actions/runs?status=queued"*)
    if [[ -n "${STUB_QUEUED_CREATED:-}" ]]; then
      printf '{"workflow_runs":[{"id":999,"name":"CI","status":"queued","created_at":"%s","html_url":"https://github.com/Org/repo/actions/runs/999"}]}\n' "$STUB_QUEUED_CREATED"
    else
      echo '{"workflow_runs":[]}'
    fi
    ;;
esac
STUB
chmod +x "${STUB_BIN}/gh"

INV="${TMP}/inventory.tsv"
printf 'hetzner\thetzner-r1\tOrg/repo\n' > "$INV"

run_mon() {
  local state_dir="$1"
  shift
  env \
    PATH="${STUB_BIN}:/usr/bin:/bin" \
    DATAMAILER_BIN="${STUB_BIN}/relay" \
    RELAY_MONITOR_CONFIG="/dev/null" \
    RELAY_ALERT_LIB="${MON_DIR}/relay-alert-lib.sh" \
    STATE_DIR="$state_dir" \
    LOCK_FILE="${state_dir}/lock" \
    RUNNER_HOSTS="hetzner" \
    RUNNER_INVENTORY_FILE="$INV" \
    GH_BIN="${STUB_BIN}/gh" \
    SYSTEMCTL_BIN="${STUB_BIN}/systemctl" \
    DF_BIN="${STUB_BIN}/df" \
    MONITOR_NOW="1795435200" \
    "$@" \
    bash "$MON_SCRIPT"
}

# ---- Test 1: All green ----
S1="${TMP}/s1"; mkdir -p "$S1"
MAIL1="${TMP}/mail1.log"; : > "$MAIL1"
REC1="${TMP}/rec1.log"; : > "$REC1"
rc=0
out="$(STUB_MAIL_LOG="$MAIL1" STUB_RECOVER_LOG="$REC1" run_mon "$S1" 2>&1)" || rc=$?
assert_eq "all-green exit 0" "$rc" "0"
assert_contains "all-green logs ALL_OK" "$out" "ALL_OK"
assert_eq "all-green sends 0 mails" "$(wc -l < "$MAIL1" | tr -d ' ')" "0"

# ---- Test 2: Stopped systemd runner -> FAIL alert + auto-recovery + dedup + RECOVERED ----
S2="${TMP}/s2"; mkdir -p "$S2"
MAIL2="${TMP}/mail2.log"; : > "$MAIL2"
REC2="${TMP}/rec2.log"; : > "$REC2"
rc=0
out="$(STUB_MAIL_LOG="$MAIL2" STUB_RECOVER_LOG="$REC2" STUB_UNIT_ACTIVE=inactive STUB_UNIT_SUB=dead \
  ALERT_TO="alexey@datatalks.club,orin@dtcdev.click,dev@dtcdev.click" \
  run_mon "$S2" 2>&1)" || rc=$?
assert_eq "stopped runner exits 1" "$rc" "1"
assert_eq "stopped runner sends 1 FAIL mail" "$(wc -l < "$MAIL2" | tr -d ' ')" "1"
assert_contains "mail routed only to dev@dtcdev.click" "$(cat "$MAIL2")" "TO=dev@dtcdev.click|SUBJECT=[gha-runner-monitor] FAIL (runner-systemd-hetzner)"
assert_contains "auto-recovery ran systemctl start" "$(cat "$REC2")" "STARTED actions.runner.Org-repo.hetzner-r1.service"

# Second run within ALERT_REPEAT_MIN -> deduped (still 1 mail)
rc=0
STUB_MAIL_LOG="$MAIL2" STUB_RECOVER_LOG="$REC2" STUB_UNIT_ACTIVE=inactive STUB_UNIT_SUB=dead \
  run_mon "$S2" >/dev/null 2>&1 || rc=$?
assert_eq "dedup run still exits 1" "$rc" "1"
assert_eq "dedup prevents second FAIL mail" "$(wc -l < "$MAIL2" | tr -d ' ')" "1"

# Recovery run -> sends RECOVERED notice (2 mails total)
rc=0
STUB_MAIL_LOG="$MAIL2" STUB_RECOVER_LOG="$REC2" STUB_UNIT_ACTIVE=active STUB_UNIT_SUB=running \
  run_mon "$S2" >/dev/null 2>&1 || rc=$?
assert_eq "recovered run exits 0" "$rc" "0"
assert_eq "recovery sends 1 RECOVERED mail" "$(wc -l < "$MAIL2" | tr -d ' ')" "2"
assert_contains "RECOVERED subject present" "$(tail -n1 "$MAIL2")" "SUBJECT=[gha-runner-monitor] RECOVERED (runner-systemd-hetzner)"

# ---- Test 3: Disk > 85% fails, == 85% passes ----
S3="${TMP}/s3"; mkdir -p "$S3"
MAIL3="${TMP}/mail3.log"; : > "$MAIL3"
REC3="${TMP}/rec3.log"; : > "$REC3"
rc=0
STUB_MAIL_LOG="$MAIL3" STUB_RECOVER_LOG="$REC3" STUB_DISK_PCT=85 run_mon "$S3" >/dev/null 2>&1 || rc=$?
assert_eq "disk 85% passes" "$rc" "0"
rc=0
STUB_MAIL_LOG="$MAIL3" STUB_RECOVER_LOG="$REC3" STUB_DISK_PCT=86 run_mon "$S3" >/dev/null 2>&1 || rc=$?
assert_eq "disk 86% fails" "$rc" "1"
assert_contains "disk 86% alerts" "$(cat "$MAIL3")" "FAIL (runner-disk-hetzner)"

# ---- Test 4: GitHub API offline runner + queue wait > 15 min ----
# MONITOR_NOW=1795435200 -> 2026-11-23T12:00:00Z; 20 min earlier is 2026-11-23T11:40:00Z
S4="${TMP}/s4"; mkdir -p "$S4"
MAIL4="${TMP}/mail4.log"; : > "$MAIL4"
REC4="${TMP}/rec4.log"; : > "$REC4"
rc=0
STUB_MAIL_LOG="$MAIL4" STUB_RECOVER_LOG="$REC4" \
  STUB_RUNNER_STATUS=offline \
  STUB_QUEUED_CREATED="2026-11-23T11:40:00Z" \
  run_mon "$S4" >/dev/null 2>&1 || rc=$?
assert_eq "offline+queued>15m fails" "$rc" "1"
assert_contains "offline runner alerted" "$(cat "$MAIL4")" "FAIL (runner-github-status)"
assert_contains "queue wait >15m alerted" "$(cat "$MAIL4")" "FAIL (runner-queue-wait)"

# ---- Test 5: GitHub API error fails loudly ----
S5="${TMP}/s5"; mkdir -p "$S5"
MAIL5="${TMP}/mail5.log"; : > "$MAIL5"
REC5="${TMP}/rec5.log"; : > "$REC5"
rc=0
STUB_MAIL_LOG="$MAIL5" STUB_RECOVER_LOG="$REC5" STUB_GH_FAIL=1 run_mon "$S5" >/dev/null 2>&1 || rc=$?
assert_eq "gh API failure exits 1" "$rc" "1"
assert_contains "gh API failure alerts loudly" "$(cat "$MAIL5")" "FAIL (runner-gh-api)"

# ---- Test 6: Cleanup script cleans idle stale files, skips busy runner ----
RBASE="${TMP}/runners"
mkdir -p "${RBASE}/idle-1/_work/_temp" "${RBASE}/idle-1/_diag" "${RBASE}/busy-1/_work/_temp"
touch -d "10 days ago" "${RBASE}/idle-1/_work/_temp/stale.tmp"
touch -d "10 days ago" "${RBASE}/idle-1/_diag/old.log"
touch -d "10 days ago" "${RBASE}/busy-1/_work/_temp/active.tmp"

# Dry run preserves everything
RUNNER_BASE_DIR="$RBASE" SKIP_SYSTEMD_HARDEN=1 DISK_USED_PCT_OVERRIDE=50 BUSY_RUNNERS_OVERRIDE="busy-1" \
  bash "$CLEANUP_SCRIPT" --dry-run >/dev/null
assert_eq "dry-run keeps idle stale tmp" "$(test -f "${RBASE}/idle-1/_work/_temp/stale.tmp" && echo yes || echo no)" "yes"

# Real run cleans idle, preserves busy
RUNNER_BASE_DIR="$RBASE" SKIP_SYSTEMD_HARDEN=1 DISK_USED_PCT_OVERRIDE=50 BUSY_RUNNERS_OVERRIDE="busy-1" \
  bash "$CLEANUP_SCRIPT" >/dev/null
assert_eq "cleanup removes idle stale tmp" "$(test -f "${RBASE}/idle-1/_work/_temp/stale.tmp" && echo yes || echo no)" "no"
assert_eq "cleanup removes old _diag log" "$(test -f "${RBASE}/idle-1/_diag/old.log" && echo yes || echo no)" "no"
assert_eq "cleanup preserves busy runner _work/_temp" "$(test -f "${RBASE}/busy-1/_work/_temp/active.tmp" && echo yes || echo no)" "yes"

echo "SUMMARY: PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
