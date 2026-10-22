#!/usr/bin/env bash
# Push DR fast-pg-raise metrics into Contabo VictoriaMetrics (contabo-a :8428).
# Hetzner has no WG path to 10.100.0.1, so we SSH to contabo-a and POST
# /api/v1/import/prometheus on localhost. Allow ~30s VM search.latencyOffset
# before vmui/instant queries show samples.
#
# Usage:
#   RESULT=pass RTO_SECONDS=26 ./contingency/push-dr-raise-metrics.sh
# Optional env:
#   HOST_LABEL (default hetzner), VM_SSH, SSH_ID, DB_SIZES_FILE (lines: <db> <bytes>)
set -euo pipefail

RESULT="${RESULT:-unknown}"
RTO_SECONDS="${RTO_SECONDS:-}"
HOST_LABEL="${HOST_LABEL:-hetzner}"
VM_SSH="${VM_SSH:-alexey@169.58.119.163}"
SSH_ID="${SSH_ID:-$HOME/.ssh/id_contabo}"
NOW="$(date +%s)"

if [[ -z "${RTO_SECONDS}" ]]; then
  echo "RTO_SECONDS required" >&2
  exit 2
fi

metrics=""
metrics+="dr_fast_pg_raise_rto_seconds{host=\"${HOST_LABEL}\",result=\"${RESULT}\"} ${RTO_SECONDS}"$'\n'
if [[ "$RESULT" == "pass" ]]; then
  metrics+="dr_fast_pg_raise_last_success_unixtime{host=\"${HOST_LABEL}\"} ${NOW}"$'\n'
  metrics+="dr_fast_pg_raise_ok{host=\"${HOST_LABEL}\"} 1"$'\n'
else
  metrics+="dr_fast_pg_raise_ok{host=\"${HOST_LABEL}\"} 0"$'\n'
fi

if [[ -n "${DB_SIZES_FILE:-}" && -f "${DB_SIZES_FILE}" ]]; then
  while read -r db bytes _; do
    [[ -z "${db:-}" || -z "${bytes:-}" ]] && continue
    [[ "$db" =~ ^[a-z0-9_]+$ ]] || continue
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    metrics+="dr_fast_pg_raise_db_bytes{host=\"${HOST_LABEL}\",db=\"${db}\"} ${bytes}"$'\n'
  done < "$DB_SIZES_FILE"
fi

metrics+="dr_fast_pg_raise_last_run_unixtime{host=\"${HOST_LABEL}\",result=\"${RESULT}\"} ${NOW}"$'\n'

code="$(printf '%s' "$metrics" | ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -i "$SSH_ID" "$VM_SSH" \
  'curl -sS -m 15 -o /dev/null -w "%{http_code}" -H "Content-Type: text/plain" --data-binary @- http://127.0.0.1:8428/api/v1/import/prometheus')"
[[ "$code" == "204" ]] || { echo "VM import HTTP $code" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.local/state/dr-fast-pg-raise}"
mkdir -p "$STATE_DIR"
printf 'LAST_RUN=%s\nLAST_RESULT=%s\nLAST_RTO=%s\n' "$NOW" "$RESULT" "$RTO_SECONDS" >"$STATE_DIR/last.env"
if [[ "$RESULT" == "pass" ]]; then
  printf 'LAST_SUCCESS=%s\nLAST_RTO=%s\n' "$NOW" "$RTO_SECONDS" >"$STATE_DIR/last_success.env"
fi

echo "pushed DR metrics result=${RESULT} rto=${RTO_SECONDS}s host=${HOST_LABEL} ts=${NOW}"
