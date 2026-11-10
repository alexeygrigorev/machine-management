#!/usr/bin/env bash
# Daily independent digest of short 5xx windows from F4 metrics.
# Runs on Hetzner and queries VictoriaMetrics over SSH; mail goes directly via
# msmtp/sendmail and never through Relay.
set -euo pipefail

ENV_FILE="${CONTABO_DEADMAN_ENV_FILE:-$HOME/.contabo-deadman.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${DIGEST_PARSER:-$HERE/contabo-503-digest.py}"
VM_SSH_HOST="${VM_SSH_HOST:-contabo-a}"
VM_SSH_TIMEOUT="${VM_SSH_TIMEOUT:-30}"
VM_API_URL="${VM_API_URL:-http://127.0.0.1:8428}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/contabo-deadman}"
LOCK_FILE="${LOCK_FILE:-$STATE_DIR/503-digest.lock}"
GAP_REPEAT_SEC="${METRICS_GAP_REPEAT_SEC:-3600}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
TO="dev@dtcdev.click"
PROM_QUERY='sum by (host, router) (increase(traefik_router_requests_total{code=~"502|503|504"}[1m]))'
UP_QUERY='min by (host) (up{job="traefik"})'
MODE="${1:---send}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
[[ "$MODE" == "--send" || "$MODE" == "--dry-run" ]] || { echo "usage: $0 [--send|--dry-run]" >&2; exit 2; }
[[ "$GAP_REPEAT_SEC" =~ ^[0-9]+$ ]] || { log "ERROR METRICS_GAP_REPEAT_SEC must be a non-negative integer"; exit 2; }
command -v ssh >/dev/null 2>&1 || { log "ERROR missing required binary: ssh"; exit 1; }
command -v timeout >/dev/null 2>&1 || { log "ERROR missing required binary: timeout"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "ERROR missing required binary: flock"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log "ERROR missing required binary: python3"; exit 1; }
[[ -r "$PARSER" ]] || { log "ERROR missing digest parser: $PARSER"; exit 1; }
umask 077
mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN another 503 digest run is active; skipping"; exit 0; }

END="$(date +%s)"
START=$((END - 86400))
fetch_vm_query() {
  local endpoint="$1" query="$2" start="$3" end="$4" payload
  payload="$(printf 'set -euo pipefail\nSTART=%q\nEND=%q\nQUERY=%q\nAPI=%q\n' \
    "$start" "$end" "$query" "$VM_API_URL")"
  if [[ "$endpoint" == "query_range" ]]; then
    payload+=$'curl -fsSG --max-time 30 --data-urlencode "query=$QUERY" --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode "step=60" "$API/api/v1/query_range"\n'
  else
    payload+=$'curl -fsSG --max-time 15 --data-urlencode "query=$QUERY" --data-urlencode "time=$END" "$API/api/v1/query"\n'
  fi
  printf '%s' "$payload" | timeout "$VM_SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM_SSH_HOST" bash -s
}

send_mail() {
  local subject="$1" body="$2" from_header="$ALERT_FROM"
  [[ -z "$ALERT_FROM_NAME" ]] || from_header="$ALERT_FROM_NAME <$ALERT_FROM>"
  if command -v msmtp >/dev/null 2>&1; then
    {
      printf 'From: %s\nTo: %s\nSubject: %s\n\n' "$from_header" "$TO" "$subject"
      printf '%s\n' "$body"
    } | msmtp -a "$ALERT_MSMTP_ACCOUNT" -f "$ALERT_FROM" -- "$TO"
  elif command -v sendmail >/dev/null 2>&1; then
    {
      printf 'From: %s\nTo: %s\nSubject: %s\n\n' "$from_header" "$TO" "$subject"
      printf '%s\n' "$body"
    } | sendmail -t -f "$ALERT_FROM"
  else
    log "ERROR no direct mail transport is installed; cannot notify $TO"
    return 1
  fi
}

gap_state="$STATE_DIR/503-metrics-gap.state"
notify_gap() {
  local detail="$1" last_alert=0 status=""
  if [[ -f "$gap_state" ]]; then
    # shellcheck disable=SC1090
    source "$gap_state" || true
    last_alert="${LAST_ALERT:-0}"; status="${STATUS:-}"
  fi
  if [[ "$status" == "FAIL" ]] && (( END - last_alert < GAP_REPEAT_SEC )); then
    log "FAIL metrics monitoring gap remains; alert repeat suppressed until ${GAP_REPEAT_SEC}s"
    return 0
  fi
  local body="F4 503 digest cannot confirm the Traefik metrics path: ${detail}. Check VictoriaMetrics, the Traefik scrape targets, and the Hetzner SSH path."
  [[ "$MODE" == "--dry-run" ]] && { printf '[monitoring-gap] %s\n' "$body"; return 0; }
  if ! send_mail "[contabo-deadman] F4 metrics monitoring gap" "$body"; then
    log "ERROR F4 metrics monitoring gap mail failed; will retry next run"
    return 1
  fi
  printf 'STATUS=FAIL\nLAST_ALERT=%s\n' "$END" > "$gap_state"
  log "ALERT F4 metrics monitoring gap sent through direct mail to $TO"
}

clear_gap() {
  local status=""
  if [[ -f "$gap_state" ]]; then
    # shellcheck disable=SC1090
    source "$gap_state" || true
    status="${STATUS:-}"
  fi
  [[ "$status" == "FAIL" ]] || return 0
  if [[ "$MODE" == "--dry-run" ]]; then
    printf '[monitoring-gap] recovered\n'
    return 0
  fi
  if ! send_mail "[contabo-deadman] F4 metrics monitoring recovered" \
    "VictoriaMetrics and both Traefik scrape targets are responding again."; then
    log "ERROR F4 metrics recovery mail failed; the failed state remains recorded"
    return 1
  fi
  printf 'STATUS=OK\nLAST_ALERT=0\n' > "$gap_state"
  log "RECOVERED F4 metrics path notified through direct mail to $TO"
}

if ! up_json="$(fetch_vm_query query "$UP_QUERY" "$START" "$END" 2>&1)"; then
  notify_gap "VictoriaMetrics query failed over SSH: $(printf '%s' "$up_json" | head -c 240)"
  exit 1
fi
if ! python3 - "$up_json" <<'PY'
import json, sys
try:
    result = json.loads(sys.argv[1])
    rows = result["data"]["result"]
    by_host = {row.get("metric", {}).get("host"): float(row["value"][1]) for row in rows}
except Exception:
    raise SystemExit(1)
if set(by_host) != {"contabo-a", "contabo-b"} or any(value < 1 for value in by_host.values()):
    raise SystemExit(1)
PY
then
  notify_gap "the instant up{job=traefik} query is missing either host or reports a scrape target down"
  exit 1
fi
if ! range_json="$(fetch_vm_query query_range "$PROM_QUERY" "$START" "$END" 2>&1)"; then
  notify_gap "VictoriaMetrics 5xx range query failed over SSH: $(printf '%s' "$range_json" | head -c 240)"
  exit 1
fi
if ! body="$(printf '%s' "$range_json" | python3 "$PARSER" "$START" "$END" 2>&1)"; then
  notify_gap "5xx range response could not be parsed: $(printf '%s' "$body" | head -c 240)"
  exit 1
fi
clear_gap

if [[ "$MODE" == "--dry-run" ]]; then
  printf '%s\n' "$body"
  exit 0
fi
digest_date="$(date -u -d "@$END" '+%Y-%m-%d')"
sent_date_file="$STATE_DIR/503-digest-last-sent-date"
if [[ -f "$sent_date_file" ]] && [[ "$(cat "$sent_date_file")" == "$digest_date" ]]; then
  log "OK daily short 503 digest already sent for ${digest_date}"
  exit 0
fi
send_mail "[contabo-deadman] daily short 503 digest" "$body"
printf '%s\n' "$digest_date" > "$sent_date_file"
log "OK daily short 503 digest sent through direct mail to $TO"
