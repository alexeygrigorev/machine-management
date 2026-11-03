#!/usr/bin/env bash
# Regression tests for monitors/ops-daily-digest.sh Relay transport.
# Verifies:
#   - T1: bash -n syntax check
#   - T2: quiet day (empty queue) sends 0 emails
#   - T3: --enqueue appends JSONL and --dry-run formats summary without mailing or clearing
#   - T4: --send uses Relay sender `alerts`, delivers to dev@ only (hard-strips alexey@), and archives queue
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/monitors/ops-daily-digest.sh"

PASS=0
FAILN=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "FAIL: $1"; }

if bash -n "$SCRIPT"; then
  pass "T1 bash -n ops-daily-digest.sh"
else
  fail "T1 bash -n ops-daily-digest.sh"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubbin" "$TMP/state"
cat > "$TMP/stubbin/datamailer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${DATAMAILER_CONFIG:-}" == "$RELAY_CONFIG_EXPECTED" ]]
[[ -z "${DATAMAILER_API_KEY:-}" && -z "${DATAMAILER_URL:-}" ]]
{
  echo "ARGS: $*"
  cat
  echo "---END---"
} >> "${STUB_MAILBOX:?}"
exit 0
EOF
chmod +x "$TMP/stubbin/datamailer"
export DATAMAILER_BIN="$TMP/stubbin/datamailer"
export RELAY_MONITOR_CONFIG="$TMP/relay.toml"
export RELAY_CONFIG_EXPECTED="$TMP/relay.toml"

MAILBOX="$TMP/mailbox"
: > "$MAILBOX"

# T2: empty queue -> no mail
out="$(STUB_MAILBOX="$MAILBOX" DIGEST_STATE_DIR="$TMP/state" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" --send 2>&1)"
if [[ "$out" == *"queue empty (0 items); nothing sent"* && ! -s "$MAILBOX" ]]; then
  pass "T2 empty digest queue sends zero emails"
else
  fail "T2 empty queue -- $out"
fi

# T3: enqueue + dry-run
DIGEST_STATE_DIR="$TMP/state" bash "$SCRIPT" --enqueue "hetzner-disk-check" "/" "WARN" "Root fs at 19% free"
DIGEST_STATE_DIR="$TMP/state" bash "$SCRIPT" --enqueue "relay-pg-dns-watchdog" "dep-worker" "AUTOHEALED" "Restarted worker"
DIGEST_STATE_DIR="$TMP/state" bash "$SCRIPT" --enqueue "coolify-healthcheck" "disk" "RECOVERED" "Disk back below 90%"
dry_out="$(STUB_MAILBOX="$MAILBOX" DIGEST_STATE_DIR="$TMP/state" PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" --dry-run 2>&1)"
if [[ "$dry_out" == *"3 total event(s)"* && ! -s "$MAILBOX" && -s "$TMP/state/queue.tsv" ]]; then
  pass "T3 --enqueue + --dry-run formats 3 events without sending or clearing queue.tsv"
else
  fail "T3 dry-run -- $dry_out"
fi

# T4: --send with DIGEST_TO containing alexey@ strips alexey@ and sends only to dev@.
send_out="$(STUB_MAILBOX="$MAILBOX" DIGEST_STATE_DIR="$TMP/state" \
  DIGEST_TO="alexey@invalid.test,dev@invalid.test" \
  PATH="$TMP/stubbin:/usr/bin:/bin" bash "$SCRIPT" --send 2>&1)"
if [[ "$send_out" == *"SENT ops-daily-digest via=relay to=dev@invalid.test items=3"* && "$send_out" != *"alexey@"* ]] \
  && grep -q '^ARGS: send --from alerts --to dev@invalid.test --subject ' "$MAILBOX" \
  && ! grep -q 'alexey@invalid.test' "$MAILBOX" \
  && ! grep -q '^ARGS: .*alexey@' "$MAILBOX" \
  && [[ ! -s "$TMP/state/queue.tsv" ]]; then
  pass "T4 --send strips alexey@, delivers to dev@invalid.test only, and rotates queue.tsv"
else
  fail "T4 --send -- $send_out -- $(cat "$MAILBOX" 2>/dev/null)"
fi

echo "---- $PASS passed, $FAILN failed ----"
[[ "$FAILN" -eq 0 ]]
