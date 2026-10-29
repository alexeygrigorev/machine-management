#!/usr/bin/env bash
# Regression (AC3): stale-check distinguishes "no attempts recorded"
# (metric missing) from "attempts recorded but failing" (run failed).
# Stubs curl only; DRY_RUN=1 so no mail or state changes.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Route by query text: success probe vs run probe.
if [[ " $* " == *'dr_fast_pg_raise_last_run_unixtime'* ]]; then
  fixture="${FIXTURE_RUN:-missing}"
else
  fixture="${FIXTURE_SUCCESS:-missing}"
fi
case "$fixture" in
  missing) echo '{"status":"success","data":{"result":[]}}';;
  unreadable) echo 'not-json';;
  *) printf '{"status":"success","data":{"result":[{"value":[0,"%s"]}]}}\n' "$fixture";;
esac
STUB
cat > "$TMP/bin/datamailer" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" DATAMAILER_BIN="$TMP/bin/datamailer"
export DR_RAISE_STALE_ENV_FILE="$TMP/no-env" STATE_DIR="$TMP/state" STALE_SECONDS=691200
export DIGEST_SCRIPT="$TMP/no-digest"

run() {
  local expected="$1"; shift
  local rc=0
  env "$@" DRY_RUN=1 bash "$REPO/monitors/dr-raise-stale-check.sh" > "$TMP/output" 2>&1 || rc=$?
  if [[ "$rc" != "$expected" ]]; then
    cat "$TMP/output"; echo "expected exit $expected got $rc" >&2; exit 1
  fi
}

# both missing -> "no attempts recorded"
run 1 FIXTURE_SUCCESS=missing FIXTURE_RUN=missing
grep -q 'no attempts recorded' "$TMP/output" || { cat "$TMP/output"; echo "missing case must say no attempts recorded" >&2; exit 1; }
echo 'PASS: missing success + missing run -> no attempts recorded'

# success missing, run fresh -> "recent attempts but no success" (failed, not missing)
run 1 FIXTURE_SUCCESS=missing FIXTURE_RUN=100
grep -q 'recent attempts but no success' "$TMP/output" || { cat "$TMP/output"; echo "failed case must say recent attempts" >&2; exit 1; }
if grep -q 'no attempts recorded' "$TMP/output"; then echo "failed case must NOT say missing" >&2; exit 1; fi
echo 'PASS: missing success + fresh run -> failing (distinct from missing)'

# success stale, run fresh -> failing within window
run 1 FIXTURE_SUCCESS=691201 FIXTURE_RUN=100
grep -q 'recent attempts but no success within 8 days' "$TMP/output" || { cat "$TMP/output"; echo "stale+fresh must say failing" >&2; exit 1; }
echo 'PASS: stale success + fresh run -> failing'

# success stale, run missing -> plain stale window message
run 1 FIXTURE_SUCCESS=691201 FIXTURE_RUN=missing
grep -q 'no successful raise within 8 days' "$TMP/output" || { cat "$TMP/output"; echo "stale case message" >&2; exit 1; }
echo 'PASS: stale success + missing run -> stale window'

# fresh success + anything -> OK
run 0 FIXTURE_SUCCESS=100 FIXTURE_RUN=missing
grep -q '^.*OK last_success' "$TMP/output"
run 0 FIXTURE_SUCCESS=100 FIXTURE_RUN=100
grep -q '^.*OK last_success' "$TMP/output"
echo 'PASS: fresh success clears regardless of run probe'

[[ ! -e "$TMP/state/stale.state" ]] || { echo "DRY_RUN must not write state" >&2; exit 1; }
echo 'ALL MISSING-VS-FAILED TESTS PASS'
