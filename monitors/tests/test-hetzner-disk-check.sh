#!/usr/bin/env bash
# Regression tests for monitors/hetzner-disk-check.sh (t1493u, intake 57cf5788).
# Runs the real script with stub df/msmtp on PATH (no root, no network, no mail).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/hetzner-disk-check.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

# ---- T1: syntax ----
if bash -n "$SCRIPT" \
  && bash -n "$REPO/monitors/install-hetzner-disk-check.sh" \
  && bash -n "$REPO/monitors/install-node-exporter.sh"; then
  pass "T1 bash -n (disk check + installers)"
else
  fail "T1 bash -n"
fi

# ---- T2: safe defaults in repo ----
check_grep() {
  if grep -qF "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}
check_grep "$SCRIPT" 'ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"' "T2a prod recipients default"
check_grep "$SCRIPT" 'ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"' "T2b ops-only drill recipient default"
check_grep "$SCRIPT" 'ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-240}"' "T2c 4h dedupe default"
check_grep "$SCRIPT" 'DISK_WARN_FREE_PCT="${DISK_WARN_FREE_PCT:-15}"' "T2d warn<15 default"
check_grep "$SCRIPT" 'DISK_CRIT_FREE_PCT="${DISK_CRIT_FREE_PCT:-8}"' "T2e crit<8 default"
check_grep "$SCRIPT" 'INODE_WARN_FREE_PCT="${INODE_WARN_FREE_PCT:-10}"' "T2f inode warn default"
check_grep "$SCRIPT" 'INODE_CRIT_FREE_PCT="${INODE_CRIT_FREE_PCT:-5}"' "T2g inode crit default"
check_grep "$SCRIPT" 'fills within' "T2h fill-within-24h logic present"
check_grep "$SCRIPT" 'storagebox' "T2i storagebox report-only present"
check_grep "$SCRIPT" 'DISK_DRILL' "T2j drill mode present"
check_grep "$REPO/monitors/hetzner-disk-check.cron" '/usr/local/sbin/hetzner-disk-check.sh' "T2k cron points at stable path"
check_grep "$REPO/monitors/install-node-exporter.sh" '127.0.0.1:9100' "T2l node_exporter loopback-only"

# ---- stub bin ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin" "$TMP/state"
MAILBOX="$TMP/mailbox"; : > "$MAILBOX"
LAST_OUT="$TMP/last_out"; LAST_RC="$TMP/last_rc"

cat > "$TMP/stubbin/df" <<'EOF'
#!/usr/bin/env bash
VALS="${STUB_VALS:-/dev/null}"
list_all() {
  echo "Filesystem Type 1B-blocks Used Available Use% Mounted on"
  while IFS='|' read -r m fst size avail ino ifree src; do
    [[ -z "$m" ]] && continue
    used=$(( size - avail ))
    usepct=0; [[ "$size" -gt 0 ]] && usepct=$(( used * 100 / size ))
    echo "$src $fst $size $used $avail ${usepct}% $m"
  done < "$VALS"
}
one_b() {
  local m="$1"
  echo "Filesystem Type 1B-blocks Used Available Use% Mounted on"
  while IFS='|' read -r mm fst size avail ino ifree src; do
    [[ "$mm" == "$m" ]] || continue
    used=$(( size - avail ))
    usepct=0; [[ "$size" -gt 0 ]] && usepct=$(( used * 100 / size ))
    echo "$src $fst $size $used $avail ${usepct}% $mm"
    return 0
  done < "$VALS"
  return 1
}
one_i() {
  local m="$1"
  echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
  while IFS='|' read -r mm fst size avail ino ifree src; do
    [[ "$mm" == "$m" ]] || continue
    iused=$(( ino - ifree ))
    ipct=0; [[ "$ino" -gt 0 ]] && ipct=$(( iused * 100 / ino ))
    echo "$src $ino $iused $ifree ${ipct}% $mm"
    return 0
  done < "$VALS"
  return 1
}
args="$*"
mp="${*: -1}"
if [[ "$args" == *"-iP"* ]]; then one_i "$mp"; exit $?
elif [[ "$args" == *"-PT"* && "$args" == *"-B1"* ]]; then
  case "$mp" in /*) one_b "$mp"; exit $?;; *) list_all; exit 0;; esac
elif [[ "$args" == *"-PT"* ]]; then list_all; exit 0
elif [[ "$args" == *"-B1"* ]]; then one_b "$mp"; exit $?
fi
echo "stub df: unsupported args: $*" >&2; exit 99
EOF
cat > "$TMP/stubbin/msmtp" <<'EOF'
#!/usr/bin/env bash
OUT="${MSMTP_OUT:-/dev/null}"
{
  echo "ARGS: $*"
  cat
  echo "---END---"
} >> "$OUT"
exit 0
EOF
chmod +x "$TMP/stubbin/df" "$TMP/stubbin/msmtp"

write_vals() { printf '%s\n' "$@" > "$TMP/vals"; }
GB=$((1073741824))

# run_iso <state-name> <envfile> : runs script, writes $LAST_OUT/$LAST_RC
run_iso() {
  local st="$1" envf="$2"
  mkdir -p "$st/samples"
  set +e
  STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$envf" \
    STATE_DIR="$st" SAMPLE_DIR="$st/samples" \
    LOCK_FILE="$TMP/lock-$RANDOM" MSMTP_OUT="$MAILBOX" \
    PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$LAST_OUT" 2>&1
  echo -n "$?" > "$LAST_RC"
  set -e
}
mkstate() { mktemp -d -p "$TMP/state"; }
mkenv() { # $1=outfile, rest=VAR lines via stdin heredoc already written by caller
  printf '%s\n' "RECOVER_NOTIFY_MIN_SEC=0" >> "$1"
}

# ---- T3: healthy mounts -> ALL_OK, one log line per mount with %free + inode ----
write_vals \
  "/|ext4|$((436*GB))|$((218*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/boot|ext3|$((1*GB))|$((750*1024*1024))|65536|64931|/dev/nvme0n1p2" \
  "/data|ext4|$((469*GB))|$((171*GB))|31260672|26582009|/dev/nvme1n1"
ST3="$(mkstate)"
cat > "$TMP/envT3" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
: > "$MAILBOX"; run_iso "$ST3" "$TMP/envT3"
out="$(cat "$LAST_OUT")"; rc="$(cat "$LAST_RC")"
if [[ "$rc" -eq 0 && "$out" == *ALL_OK* \
  && "$out" == *check=disk-root* && "$out" == *check=disk-boot* && "$out" == *check=disk-data* \
  && "$out" == *free=* && "$out" == *inode=* ]]; then
  pass "T3 healthy mounts green with per-mount %free + inode (rc=$rc)"
else
  fail "T3 healthy (rc=$rc) -- $out"
fi
if [[ ! -s "$MAILBOX" ]]; then pass "T3b no mail when green"; else fail "T3b unexpected mail: $(cat "$MAILBOX")"; fi

# ---- T4: / at ~12% free -> WARN, pages prod, dedupes within 4h ----
write_vals \
  "/|ext4|$((436*GB))|$((52*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/boot|ext3|$((1*GB))|$((750*1024*1024))|65536|64931|/dev/nvme0n1p2" \
  "/data|ext4|$((469*GB))|$((171*GB))|31260672|26582009|/dev/nvme1n1"
ST4="$(mkstate)"
cat > "$TMP/envT4" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
: > "$MAILBOX"
set +e
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT4" STATE_DIR="$ST4" SAMPLE_DIR="$ST4/samples" LOCK_FILE="$TMP/lock-t4a" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/o1" 2>&1; rc1=$?
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT4" STATE_DIR="$ST4" SAMPLE_DIR="$ST4/samples" LOCK_FILE="$TMP/lock-t4b" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/o2" 2>&1; rc2=$?
set -e
out1="$(cat "$TMP/o1")"; out2="$(cat "$TMP/o2")"
mails="$(grep -c '^ARGS:' "$MAILBOX" || true)"
if [[ "$rc1" -ne 0 && "$out1" == *WARN* && "$out1" == *disk-root* && "$mails" -eq 1 ]] \
  && grep -q 'prod-a@example.test' "$MAILBOX" && grep -q 'prod-b@example.test' "$MAILBOX"; then
  pass "T4 warn pages prod once (rc=$rc1)"
else
  fail "T4 warn (rc1=$rc1 rc2=$rc2 mails=$mails) -- $out1 || $out2"
fi
if [[ "$rc2" -ne 0 && "$mails" -eq 1 ]]; then
  pass "T4b second failing run deduped (no mail spam)"
else
  fail "T4b dedupe (rc2=$rc2 mails=$mails)"
fi

# ---- T5: crit space (5% free) + crit inode (3% free) ----
write_vals \
  "/|ext4|$((436*GB))|$((21*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/boot|ext3|$((1*GB))|$((750*1024*1024))|65536|64931|/dev/nvme0n1p2" \
  "/data|ext4|$((469*GB))|$((171*GB))|31260672|936821|/dev/nvme1n1"
ST5="$(mkstate)"
cat > "$TMP/envT5" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
: > "$MAILBOX"; run_iso "$ST5" "$TMP/envT5"
out="$(cat "$LAST_OUT")"; rc="$(cat "$LAST_RC")"
if [[ "$rc" -ne 0 && "$out" == *FAIL*check=disk-root* && "$out" == *FAIL*check=disk-data* ]]; then pass "T5 crit space+inode FAILs"; else fail "T5 crit (rc=$rc) -- $out"; fi

# ---- T6: storagebox 95% full is report-only, never paged ----
write_vals \
  "/|ext4|$((436*GB))|$((218*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/boot|ext3|$((1*GB))|$((750*1024*1024))|65536|64931|/dev/nvme0n1p2" \
  "/data|ext4|$((469*GB))|$((171*GB))|31260672|26582009|/dev/nvme1n1" \
  "/home/alexey/storagebox|fuse.sshfs|$((1024*GB))|$((50*GB))|2047865007|2047759766|u685332@storagebox"
ST6="$(mkstate)"
cat > "$TMP/envT6" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
: > "$MAILBOX"; run_iso "$ST6" "$TMP/envT6"
out="$(cat "$LAST_OUT")"; rc="$(cat "$LAST_RC")"
if [[ "$rc" -eq 0 && "$out" == *INFO*storagebox* && ! -s "$MAILBOX" ]]; then
  pass "T6 storagebox report-only, no page"
else
  fail "T6 storagebox (rc=$rc) -- $out / mail: $(cat "$MAILBOX")"
fi

# ---- T7: fill trend -> CRIT even when free% looks healthy ----
ST7="$(mkstate)"; mkdir -p "$ST7/samples"
write_vals \
  "/|ext4|$((100*GB))|$((40*GB))|29097984|20604622|/dev/nvme0n1p3"
now="$(date +%s)"; sixh=$(( now - 6*3600 )); threeh=$(( now - 3*3600 ))
printf '%s %s %s\n' "$sixh" "$((80*GB))" "$((100*GB))" > "$ST7/samples/root.log"
printf '%s %s %s\n' "$threeh" "$((60*GB))" "$((100*GB))" >> "$ST7/samples/root.log"
cat > "$TMP/envT7" <<EOF
DISK_MOUNTS="/"
ALERT_TO=prod-a@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
FILL_WINDOW_H=6
FILL_CRIT_H=24
EOF
: > "$MAILBOX"; run_iso "$ST7" "$TMP/envT7"
out="$(cat "$LAST_OUT")"; rc="$(cat "$LAST_RC")"
if [[ "$rc" -ne 0 && "$out" == *fills\ within* ]]; then pass "T7 fill-trend CRIT (fills within 24h)"; else fail "T7 trend (rc=$rc) -- $out"; fi

# ---- T8: drill goes to ops-only with timestamp, then clears ----
ST8="$(mkstate)"
write_vals \
  "/|ext4|$((436*GB))|$((218*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/boot|ext3|$((1*GB))|$((750*1024*1024))|65536|64931|/dev/nvme0n1p2" \
  "/data|ext4|$((469*GB))|$((171*GB))|31260672|26582009|/dev/nvme1n1"
cat > "$TMP/envT8a" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
DISK_DRILL=1
EOF
cat > "$TMP/envT8b" <<EOF
DISK_MOUNTS="/ /boot /data"
ALERT_TO=prod-a@example.test,prod-b@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
DISK_DRILL=0
EOF
: > "$MAILBOX"
set +e
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT8a" STATE_DIR="$ST8" SAMPLE_DIR="$ST8/samples" LOCK_FILE="$TMP/lock-t8a" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/od" 2>&1; rcd=$?
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT8b" STATE_DIR="$ST8" SAMPLE_DIR="$ST8/samples" LOCK_FILE="$TMP/lock-t8b" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/oc" 2>&1; rcc=$?
set -e
outd="$(cat "$TMP/od")"; outc="$(cat "$TMP/oc")"
if [[ "$rcd" -ne 0 && "$outd" == *DRILL* && "$outc" == *ALL_OK* \
  && "$(grep -c '^ARGS:' "$MAILBOX")" -eq 2 ]] \
  && grep -q 'ops@example.test' "$MAILBOX" \
  && ! grep -q 'prod-a@example.test' "$MAILBOX" && grep -q 'RECOVERED' "$MAILBOX"; then
  pass "T8 drill to ops-only with timestamp, then RECOVERED + clear"
else
  fail "T8 drill (rcd=$rcd rcc=$rcc) -- drill: $outd || clear: $outc || mail: $(cat "$MAILBOX")"
fi

# ---- T9: tmpfs excluded ----
write_vals \
  "/|ext4|$((436*GB))|$((218*GB))|29097984|20604622|/dev/nvme0n1p3" \
  "/run|tmpfs|$((6*GB))|$((6*GB))|1644130|1642929|tmpfs"
ST9="$(mkstate)"
cat > "$TMP/envT9" <<EOF
DISK_MOUNTS="/ /run"
ALERT_TO=prod-a@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
: > "$MAILBOX"; run_iso "$ST9" "$TMP/envT9"
out="$(cat "$LAST_OUT")"; rc="$(cat "$LAST_RC")"
if [[ "$out" == *SKIP* ]]; then pass "T9 tmpfs excluded"; else fail "T9 tmpfs (rc=$rc) -- $out"; fi

# ---- T10: failed send must not start the dedupe window (review FIX1) ----
mkdir -p "$TMP/stubbin-fail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stubbin-fail/msmtp"
chmod +x "$TMP/stubbin-fail/msmtp"
write_vals \
  "/|ext4|$((436*GB))|$((52*GB))|29097984|20604622|/dev/nvme0n1p3"
ST10="$(mkstate)"
cat > "$TMP/envT10" <<EOF
DISK_MOUNTS="/"
ALERT_TO=prod-a@example.test
ALERT_OPS_TO=ops@example.test
RECOVER_NOTIFY_MIN_SEC=0
EOF
set +e
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT10" STATE_DIR="$ST10" SAMPLE_DIR="$ST10/samples" LOCK_FILE="$TMP/lock-t10a" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin-fail:$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/o10a" 2>&1; rc10a=$?
STUB_VALS="$TMP/vals" HETZNER_DISK_ENV_FILE="$TMP/envT10" STATE_DIR="$ST10" SAMPLE_DIR="$ST10/samples" LOCK_FILE="$TMP/lock-t10b" MSMTP_OUT="$MAILBOX" PATH="$TMP/stubbin-fail:$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" >"$TMP/o10b" 2>&1; rc10b=$?
set -e
out10a="$(cat "$TMP/o10a")"; out10b="$(cat "$TMP/o10b")"
last_alert="$(grep LAST_ALERT "$ST10/disk-root.state" | cut -d= -f2)"
if [[ "$rc10a" -ne 0 && "$rc10b" -ne 0 && "$last_alert" == "0" \
  && "$out10a" == *WARN*msmtp*failed* && "$out10b" == *WARN*msmtp*failed* ]]; then
  pass "T10 failed send retries immediately (no 4h mute)"
else
  fail "T10 failed-send retry (rc=$rc10a/$rc10b last=$last_alert) -- $out10a || $out10b"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
