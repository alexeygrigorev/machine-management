#!/usr/bin/env bash
# Regression: mirror-dr-raise-metrics.sh copies the newest DR series verbatim
# into contabo-a, pushes nothing when the source is empty, fails loudly on
# source/remote errors, and never contacts Contabo when VM_SSH="".
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export SSH_BODY="$TMP/ssh.body" SSH_LOG="$TMP/ssh.log" CURL_LOG="$TMP/curl.log"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CURL_LOG"
case "$FIXTURE" in
  full) cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
{"metric":{"__name__":"dr_fast_pg_raise_last_success_unixtime","host":"hetzner"},"value":[1793351205,"1793258233"]},
{"metric":{"__name__":"dr_fast_pg_raise_rto_seconds","host":"hetzner","result":"pass"},"value":[1793351205,"28"]},
{"metric":{"__name__":"dr_fast_pg_raise_db_bytes","host":"hetzner","db":"we\"ird"},"value":[1793351205,"42"]}]}}
JSON
  ;;
  empty) echo '{"status":"success","data":{"resultType":"vector","result":[]}}';;
  error) exit 22;;
  garbage) echo 'not json';;
esac
STUB
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >> "$SSH_LOG"
cat > "$SSH_BODY"
printf '%s' "${REMOTE_CODE:-204}"
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

run() {
  local expected="$1"; shift
  local rc=0
  env "$@" bash "$REPO/contingency/mirror-dr-raise-metrics.sh" > "$TMP/out" 2>&1 || rc=$?
  if [[ "$rc" != "$expected" ]]; then
    cat "$TMP/out"; echo "expected exit $expected, got $rc" >&2; exit 1
  fi
}
bash -n "$REPO/contingency/mirror-dr-raise-metrics.sh"

# 1) Full source -> verbatim values (real run timestamps), escaped labels, one push.
rm -f "$SSH_BODY" "$SSH_LOG"
run 0 FIXTURE=full VM_SSH=alexey@contabo-a.invalid.test
grep -q 'mirror series=3 remote=ok' "$TMP/out"
grep -qx 'dr_fast_pg_raise_last_success_unixtime{host="hetzner"} 1793258233' "$SSH_BODY"
grep -qx 'dr_fast_pg_raise_rto_seconds{host="hetzner",result="pass"} 28' "$SSH_BODY"
grep -qx 'dr_fast_pg_raise_db_bytes{db="we\\"ird",host="hetzner"} 42' "$SSH_BODY"
[[ "$(wc -l < "$SSH_LOG")" == 1 ]]
grep -q 'BatchMode=yes' "$SSH_LOG"
grep -q 'host=~\\"hetzner\\"\|host=~"hetzner"' "$CURL_LOG"
echo 'PASS: newest DR series mirrored verbatim with escaped labels'

# 2) Empty source -> no push, exit 0 (contabo-a then goes missing honestly).
rm -f "$SSH_BODY" "$SSH_LOG"
run 0 FIXTURE=empty VM_SSH=alexey@contabo-a.invalid.test
grep -q 'nothing to mirror' "$TMP/out"
[[ ! -e "$SSH_LOG" ]]
echo 'PASS: empty source pushes nothing'

# 3) Source query failure / garbage -> exit 1, no push.
for fx in error garbage; do
  rm -f "$SSH_LOG"
  run 1 FIXTURE="$fx" VM_SSH=alexey@contabo-a.invalid.test
  grep -q 'ERROR' "$TMP/out"
  [[ ! -e "$SSH_LOG" ]]
done
echo 'PASS: source failures are loud and push nothing'

# 4) Remote import rejected -> exit 1.
run 1 FIXTURE=full VM_SSH=alexey@contabo-a.invalid.test REMOTE_CODE=400
grep -q 'ERROR: remote VM import HTTP 400' "$TMP/out"
echo 'PASS: remote import failure is loud'

# 5) VM_SSH="" -> print only, never ssh.
rm -f "$SSH_LOG"
run 0 FIXTURE=full VM_SSH=""
grep -q 'remote=skipped' "$TMP/out"
grep -q '^dr_fast_pg_raise_rto_seconds' "$TMP/out"
[[ ! -e "$SSH_LOG" ]]
echo 'PASS: VM_SSH="" never contacts Contabo'
