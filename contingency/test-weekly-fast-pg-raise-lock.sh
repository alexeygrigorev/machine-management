#!/usr/bin/env bash
# Regression test: weekly-fast-pg-raise single lock owner (fix 2026-10-27).
#
# Background: cron used to wrap the script in `/usr/bin/flock -n` on the
# SAME file the script itself locks (`flock -n 9`). The inner lock always
# failed, so every cron run logged "another weekly raise is running" and
# exited 0 without doing anything (silent no-op since 2026-10-22).
#
# What this tests (all with mocked ssh/scp/docker + stubbed raise/push):
#   0. Mechanism: nested `flock -n` on the same file always fails (root cause).
#   1. Running the exact command from weekly-fast-pg-raise.cron actually
#      executes the raise (stub marker) and finishes with `done result=pass`.
#   2. A genuinely concurrent second run is skipped: distinct SKIP log line,
#      no raise execution, non-zero exit (75) — never mistaken for success.
#   3. Static: repo cron has no outer flock (script is the single lock owner).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_FILE="$REPO_ROOT/contingency/weekly-fast-pg-raise.cron"
SCRIPT="$REPO_ROOT/contingency/weekly-fast-pg-raise.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/weekly-raise-lock-test.XXXXXX")"
HOLDER_PID=""
cleanup() { kill "$HOLDER_PID" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

FAKEHOME="$T/home"; mkdir -p "$FAKEHOME"
SHIM="$T/bin"; mkdir -p "$SHIM"

# --- shims ---
cat >"$SHIM/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake Contabo ssh: only emulates what weekly-fast-pg-raise.sh needs.
if [[ "$*" == *"docker ps"* ]]; then
  printf 'fake-pg-shared\nfake-pg-relay\n'
  exit 0
fi
exit 0
EOF
cat >"$SHIM/scp" <<'EOF'
#!/usr/bin/env bash
# Fake scp: materialise the 4 dumps the script expects in $RAW.
# src looks like host:/home/alexey/tmp/weekly-fast-pg-raise-dumps/<STAMP>/*.dump
dest="${@: -1}"
src=""
for a in "$@"; do [[ "$a" == *:* ]] && src="$a"; done
remote="${src#*:}"
stamp="$(basename "$(dirname "$remote")")"
for f in "cmp-pg-shared-${stamp}.dump" "aisl-pg-shared-${stamp}.dump" \
         "website-pg-shared-${stamp}.dump" "relay-pg-relay-${stamp}.dump"; do
  printf 'fake-dump %s\n' "$f" >"$dest/$f"
done
exit 0
EOF
cat >"$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: pull/teardown succeed; `ps` reports nothing (sizes skipped).
[[ "${1:-}" == "ps" ]] && exit 1
exit 0
EOF
chmod +x "$SHIM"/ssh "$SHIM"/scp "$SHIM"/docker

RAISE_STUB="$T/raise-stub.sh"
cat >"$RAISE_STUB" <<'EOF'
#!/usr/bin/env bash
ls "$DUMPS_DIR"/*.dump >/dev/null || { echo "STUB: dumps missing" >&2; exit 2; }
printf 'raise-stub ran container=%s dumps=%s\n' "$CONTAINER" "$DUMPS_DIR" >"$STUB_DIR/raise-stub-ran"
echo "STUB RAISE ok"
EOF
PUSH_STUB="$T/push-stub.sh"
cat >"$PUSH_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'RESULT=%s RTO=%s\n' "${RESULT:-?}" "${RTO_SECONDS:-?}" >"$STUB_DIR/push-stub-ran"
echo "STUB PUSH ok"
EOF
chmod +x "$RAISE_STUB" "$PUSH_STUB"

# --- extract installed cron command line ---
CRON_LINE="$(grep -v -e '^#' -e '^[[:space:]]*$' "$CRON_FILE" | grep -v '^SHELL=' | grep -v '^PATH=' | grep -v '^CRON_TZ=' | tail -n 1)"
CMD="$(echo "$CRON_LINE" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}')"
LOGFILE="$(echo "$CMD" | sed -n 's/.*>> *\([^ ]*\).*/\1/p')"
RUN="$(echo "$CMD" | sed 's/ *>>.*//; s/ *2>&1.*//')"

# --- test 3 (static): single lock owner (only non-comment lines count) ---
if grep -v '^#' "$CRON_FILE" | grep -q 'flock'; then
  bad "repo cron still contains flock (double-lock risk)"
else
  ok "repo cron has no outer flock (script is single lock owner)"
fi
if [[ "$LOGFILE" == "/home/alexey/.local/state/dr-fast-pg-raise/weekly.log" ]]; then
  ok "cron still appends to canonical weekly.log"
else
  bad "unexpected cron log target: $LOGFILE"
fi
if [[ "$RUN" == *"weekly-fast-pg-raise.sh"* ]]; then
  ok "cron invokes weekly-fast-pg-raise.sh: $RUN"
else
  bad "cannot find script invocation in cron line: $CRON_LINE"
fi
# The cron line points at the stable installed copy (install-weekly-fast-pg-raise.sh,
# 68147e6c); for the test we run the identical command with the script path
# swapped to this checkout.
RUN_UNDER_TEST="${RUN//\/usr\/local\/lib\/dr-fast-pg-raise\/contingency\/weekly-fast-pg-raise.sh/$SCRIPT}"
if [[ "$RUN_UNDER_TEST" != "$RUN" ]]; then
  ok "test swaps production script path for checkout under test"
else
  bad "could not map cron script path to checkout under test"
fi
ACQ="$(grep -c 'flock -n 9' "$SCRIPT" || true)"
[[ "$ACQ" == "1" ]] && ok "script acquires the lock exactly once" || bad "script lock acquisitions: $ACQ"
grep -q 'exit 75' "$SCRIPT" && ok "contended path exits non-zero (75)" || bad "no non-zero contended exit"

# --- test 0: root-cause mechanism ---
MECH_LOCK="$T/mech.lock"
if /usr/bin/flock -n "$MECH_LOCK" bash -c 'exec 9>"'"$MECH_LOCK"'"; flock -n 9'; then
  bad "nested flock on same file unexpectedly succeeded"
else
  ok "nested flock -n on same file always fails (root cause reproduced)"
fi

run_cron_cmd() { # $1 = output file; rest of RUN via bash -c
  local out="$1"
  env -i PATH="$SHIM:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="$FAKEHOME" LOCK="$T/weekly.lock" STUB_DIR="$T" \
    RAISE_SH="$RAISE_STUB" PUSH_SH="$PUSH_STUB" \
    bash -c "$RUN_UNDER_TEST" >"$out" 2>&1
}

# --- test 1: cron command actually executes the raise ---
rm -f "$T/raise-stub-ran" 2>/dev/null || true
set +e
run_cron_cmd "$T/run1.log"
RC1=$?
set -e
[[ "$RC1" == "0" ]] && ok "uncontended cron run exits 0" || bad "uncontended exit=$RC1 (log: $(tail -3 "$T/run1.log" | tr '\n' '|'))"
[[ -f "$T/raise-stub-ran" ]] && ok "raise executed via cron command ($(cat "$T/raise-stub-ran"))" || bad "raise stub never ran"
grep -q 'RESULT=pass' "$T/push-stub-ran" 2>/dev/null && ok "metrics push called with RESULT=pass" || bad "push stub missing/not pass"
grep -q 'done result=pass' "$T/run1.log" && ok "log ends with done result=pass" || bad "no success line in run log"
grep -q 'SKIP' "$T/run1.log" && bad "uncontended run logged SKIP" || ok "no SKIP in successful run"

# --- test 2: genuinely concurrent second run is skipped ---
rm -f "$T/raise-stub-ran" "$T/push-stub-ran"
# Hold the same $LOCK the script uses.
/usr/bin/flock -n "$T/weekly.lock" sleep 60 &
HOLDER_PID=$!
sleep 0.5
set +e
run_cron_cmd "$T/run2.log"
RC2=$?
set -e
[[ "$RC2" != "0" ]] && ok "contended run exits non-zero ($RC2), not success" || bad "contended run exited 0 (looks like success)"
[[ ! -f "$T/raise-stub-ran" ]] && ok "contended run did not execute the raise" || bad "raise ran despite contention"
grep -q 'SKIP: another weekly raise is running (lock contended' "$T/run2.log" \
  && ok "contended run left SKIP log line" \
  || bad "no SKIP line (got: $(cat "$T/run2.log" | tr '\n' '|'))"
grep -q 'done result=' "$T/run2.log" && bad "contended run logged a result line" || ok "no success-like result line on skip"
kill "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""
wait 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == "0" ]]
