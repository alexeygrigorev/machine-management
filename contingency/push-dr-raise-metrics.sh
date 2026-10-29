#!/usr/bin/env bash
# Push DR fast-pg-raise metrics into VictoriaMetrics.
#
# Primary: direct POST to $VM_URL (default http://127.0.0.1:8428)
# /api/v1/import/prometheus on the box running the weekly raise (Hetzner).
# That local VM keeps 400d, so a weekly success survives the 8d dead-man
# window. Previously this script only SSH-pushed to contabo-a, whose hot
# VM keeps ~2d (see observability/README) — a weekly success expired
# before the stale-check window, so dr_* never stayed queryable.
#
# Secondary (default on): also SSH to contabo-a and POST on localhost so
# the contabo-a stale-check keeps seeing fresh samples until it migrates.
# Set VM_SSH="" to skip the remote leg (tests, local-only drills — no
# Contabo contact). Allow ~30s VM search.latencyOffset before
# vmui/instant queries show samples (label __name__ values show them
# immediately).
#
# Usage:
#   RESULT=pass RTO_SECONDS=26 ./contingency/push-dr-raise-metrics.sh
# Optional env:
#   HOST_LABEL (default hetzner), VM_URL, VM_SSH, SSH_ID, DB_SIZES_FILE (lines: <db> <bytes>)
set -euo pipefail

RESULT="${RESULT:-unknown}"
RTO_SECONDS="${RTO_SECONDS:-}"
HOST_LABEL="${HOST_LABEL:-hetzner}"
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
# Empty VM_SSH ("") skips the remote leg; unset VM_SSH keeps the default.
# (Plain "-" not ":-" so that an explicit empty value is honored.)
VM_SSH="${VM_SSH-alexey@169.58.119.163}"
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

code="$(printf '%s' "$metrics" | curl -sS -m 15 -o /dev/null -w "%{http_code}" \
  -H "Content-Type: text/plain" --data-binary @- "${VM_URL}/api/v1/import/prometheus")"
[[ "$code" == "204" ]] || { echo "local VM import HTTP $code (url=${VM_URL})" >&2; exit 1; }

remote_note="remote=skipped"
if [[ -n "${VM_SSH}" ]]; then
  code="$(printf '%s' "$metrics" | ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -i "$SSH_ID" "$VM_SSH" \
    'curl -sS -m 15 -o /dev/null -w "%{http_code}" -H "Content-Type: text/plain" --data-binary @- http://127.0.0.1:8428/api/v1/import/prometheus')"
  if [[ "$code" == "204" ]]; then
    remote_note="remote=ok"
  else
    echo "WARN: remote VM import HTTP $code via ${VM_SSH}; local push already landed" >&2
    remote_note="remote=HTTP_${code}"
  fi
fi

STATE_DIR="${STATE_DIR:-$HOME/.local/state/dr-fast-pg-raise}"
mkdir -p "$STATE_DIR"
printf 'LAST_RUN=%s\nLAST_RESULT=%s\nLAST_RTO=%s\n' "$NOW" "$RESULT" "$RTO_SECONDS" >"$STATE_DIR/last.env"
if [[ "$RESULT" == "pass" ]]; then
  printf 'LAST_SUCCESS=%s\nLAST_RTO=%s\n' "$NOW" "$RTO_SECONDS" >"$STATE_DIR/last_success.env"
fi

echo "pushed DR metrics result=${RESULT} rto=${RTO_SECONDS}s host=${HOST_LABEL} ts=${NOW} ${remote_note}"
if [[ "$remote_note" != "remote=ok" && "$remote_note" != "remote=skipped" ]]; then
  exit 1
fi
