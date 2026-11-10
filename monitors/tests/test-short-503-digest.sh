#!/usr/bin/env bash
# Offline integration test for the direct 503 digest and metrics-gap page.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/monitors/contabo-503-digest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/mail"
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
if grep -q 'traefik_router_requests_total' <<<"$input"; then
  cat "$TEST_RANGE_JSON"
else
  cat "$TEST_UP_JSON"
fi
STUB
cat > "$TMP/bin/msmtp" <<'STUB'
#!/usr/bin/env bash
message="$(cat)"
printf '%s\n---\n' "$message" >> "$TEST_MAIL_DIR/messages.txt"
printf '%s\n' "$*" >> "$TEST_MAIL_DIR/args.txt"
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/msmtp"

cat > "$TMP/up.json" <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"host":"contabo-a"},"value":[1700000000,"1"]},
  {"metric":{"host":"contabo-b"},"value":[1700000000,"1"]}
]}}
JSON
cat > "$TMP/range.json" <<'JSON'
{"status":"success","data":{"resultType":"matrix","result":[
  {"metric":{"host":"contabo-b","router":"relay@docker"},"values":[[1700000000,"3"]]}
]}}
JSON
export TEST_UP_JSON="$TMP/up.json" TEST_RANGE_JSON="$TMP/range.json" TEST_MAIL_DIR="$TMP/mail"

OUT="$(CONTABO_DEADMAN_ENV_FILE=/nonexistent STATE_DIR="$TMP/state" LOCK_FILE="$TMP/state.lock" \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" --dry-run)"
[[ "$OUT" == *"relay@docker"* && "$OUT" == *"60s"* ]]
[[ ! -e "$TMP/mail/messages.txt" ]]

CONTABO_DEADMAN_ENV_FILE=/nonexistent STATE_DIR="$TMP/state" LOCK_FILE="$TMP/state.lock" \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" --send >/dev/null
[[ "$(grep -c '^Subject: \[contabo-deadman\] daily short 503 digest$' "$TMP/mail/messages.txt")" == 1 ]]
grep -q '^To: dev@dtcdev.click$' "$TMP/mail/messages.txt"
grep -q -- '-a alerts -f alerts@dtcdev.click -- dev@dtcdev.click' "$TMP/mail/args.txt"

cat > "$TMP/up-gap.json" <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"host":"contabo-a"},"value":[1700000000,"1"]}
]}}
JSON
export TEST_UP_JSON="$TMP/up-gap.json"
set +e
OUT="$(CONTABO_DEADMAN_ENV_FILE=/nonexistent STATE_DIR="$TMP/state" LOCK_FILE="$TMP/state.lock" \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" --send 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 && "$OUT" == *"monitoring gap sent through direct mail"* ]]
[[ "$(grep -c '^Subject: \[contabo-deadman\] F4 metrics monitoring gap$' "$TMP/mail/messages.txt")" == 1 ]]

# A successful scrape-target query is not enough to clear a gap if the range
# query fails later in the same run.
cat > "$TMP/range-error.json" <<'JSON'
{"status":"error","error":"store unavailable"}
JSON
export TEST_RANGE_JSON="$TMP/range-error.json"
printf 'STATUS=FAIL\nLAST_ALERT=0\n' > "$TMP/state/503-metrics-gap.state"
: > "$TMP/mail/messages.txt"
set +e
OUT="$(CONTABO_DEADMAN_ENV_FILE=/nonexistent STATE_DIR="$TMP/state" LOCK_FILE="$TMP/state.lock" \
  PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" --send 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 && "$(grep -c '^Subject: \[contabo-deadman\] F4 metrics monitoring gap$' "$TMP/mail/messages.txt")" == 1 ]]
! grep -q '^Subject: \[contabo-deadman\] F4 metrics monitoring recovered$' "$TMP/mail/messages.txt"
printf 'PASS: daily short-503 digest and independent metrics-gap page use direct mail\n'
