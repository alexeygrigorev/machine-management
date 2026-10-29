#!/usr/bin/env bash
# Regression: push-dr-raise-metrics.sh lands locally without Contabo contact.
# Stubs curl (records body, answers 204) and ssh (must not run when VM_SSH="").
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
export PUSH_BODY="$TMP/body.txt" SSH_CALLED="$TMP/ssh.called" CURL_LOG="$TMP/curl.log"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CURL_LOG"
cat > "$PUSH_BODY"
printf '204'
exit 0
STUB
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >> "$CURL_LOG"
touch "$SSH_CALLED"
if [[ "${SSH_REMOTE_CODE:-204}" != "204" ]]; then
  printf '%s' "${SSH_REMOTE_CODE}"
  exit 0
fi
cat > /dev/null
printf '204'
exit 0
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

run_push() { env "$@" bash "$REPO/contingency/push-dr-raise-metrics.sh"; }

# 1) local-only: no SSH contact, exit 0, expected series in body
rm -f "$PUSH_BODY" "$SSH_CALLED"
out="$(run_push RESULT=pass RTO_SECONDS=28 VM_URL=http://127.0.0.1:8428 VM_SSH="" STATE_DIR="$TMP/state")"
[[ "$out" == *"pushed DR metrics result=pass"* ]] || { echo "missing pushed line: $out" >&2; exit 1; }
[[ "$out" == *"remote=skipped"* ]] || { echo "missing remote=skipped: $out" >&2; exit 1; }
[[ ! -e "$SSH_CALLED" ]] || { echo "ssh must not run when VM_SSH empty" >&2; exit 1; }
grep -q 'dr_fast_pg_raise_rto_seconds{host="hetzner",result="pass"} 28' "$PUSH_BODY"
grep -q 'dr_fast_pg_raise_last_success_unixtime{host="hetzner"}' "$PUSH_BODY"
grep -q 'dr_fast_pg_raise_ok{host="hetzner"} 1' "$PUSH_BODY"
grep -q 'dr_fast_pg_raise_last_run_unixtime{host="hetzner",result="pass"}' "$PUSH_BODY"
grep -q 'LAST_RESULT=pass' "$TMP/state/last.env"
grep -q 'LAST_SUCCESS=' "$TMP/state/last_success.env"
echo 'PASS: local-only push lands without SSH'

# 2) fail result writes ok=0 and no last_success.env
rm -rf "$TMP/state" "$PUSH_BODY"
mkdir -p "$TMP/state"
out="$(run_push RESULT=fail RTO_SECONDS=11 VM_URL=http://127.0.0.1:8428 VM_SSH="" STATE_DIR="$TMP/state")"
grep -q 'dr_fast_pg_raise_ok{host="hetzner"} 0' "$PUSH_BODY"
[[ ! -e "$TMP/state/last_success.env" ]] || { echo "fail must not write last_success.env" >&2; exit 1; }
echo 'PASS: fail result writes ok=0 without success stamp'

# 3) dual mode calls ssh too
rm -f "$PUSH_BODY" "$SSH_CALLED"
out="$(run_push RESULT=pass RTO_SECONDS=28 VM_URL=http://127.0.0.1:8428 VM_SSH=example.invalid STATE_DIR="$TMP/state")"
[[ "$out" == *"remote=ok"* ]] || { echo "missing remote=ok: $out" >&2; exit 1; }
[[ -e "$SSH_CALLED" ]] || { echo "ssh must run when VM_SSH set" >&2; exit 1; }
echo 'PASS: dual push reaches remote leg'

# 4) remote failure: local landed, exit 1 with WARN
rm -f "$PUSH_BODY" "$SSH_CALLED"
rc=0
out="$(SSH_REMOTE_CODE=500 run_push RESULT=pass RTO_SECONDS=28 VM_URL=http://127.0.0.1:8428 VM_SSH=example.invalid STATE_DIR="$TMP/state")" || rc=$?
[[ "$rc" == 1 ]] || { echo "expected exit 1 on remote failure, got $rc" >&2; exit 1; }
[[ -s "$PUSH_BODY" ]] || { echo "local body must land before remote failure" >&2; exit 1; }
echo 'PASS: remote failure keeps local data and exits 1'

# 5) RTO_SECONDS required
rc=0
SSH_REMOTE_CODE=204 run_push RESULT=pass VM_URL=http://127.0.0.1:8428 VM_SSH="" STATE_DIR="$TMP/state" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || { echo "expected exit 2 without RTO, got $rc" >&2; exit 1; }
echo 'PASS: RTO_SECONDS required'

echo 'ALL PUSH TESTS PASS'
