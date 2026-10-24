#!/usr/bin/env bash
# Dead-man for weekly Contabo→alt-host fast PG raise.
#
# Alerts to ALERT_TO (default alexey@datatalks.club,dev@dtcdev.click) via Relay when:
#   - VictoriaMetrics has no dr_fast_pg_raise_last_success_unixtime, OR
#   - (time() - last_success) > STALE_SECONDS (default 8 days = 691200)
#
# Prefer running on contabo-a (local VM + dedicated Relay client).
# Cron: daily 09:00 Europe/Berlin (see dr-raise-stale-check.cron).
# DRY_RUN=1 queries and logs only; no email or state changes.
set -euo pipefail

ENV_FILE="${DR_RAISE_STALE_ENV_FILE:-/etc/dr-raise-stale-check.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"

# One client/key for Contabo monitors, stored root-owned mode 0600. The CLI
# loads it from disk; credentials never appear in process arguments or logs.
relay_alert() {
  local recipients="${1// /,}" subject="$2" body="$3" recipient sent=0
  local -a addresses=()
  IFS=',' read -r -a addresses <<< "$recipients"
  for recipient in "${addresses[@]}"; do
    [[ -n "$recipient" ]] || continue
    if ! printf '%s\n' "$body" | env -u DATAMAILER_API_KEY -u DATAMAILER_URL \
      DATAMAILER_CONFIG="${RELAY_MONITOR_CONFIG:-/etc/relay-monitors.toml}" \
      "${DATAMAILER_BIN:-/usr/local/bin/datamailer}" send --from alerts \
      --to "$recipient" --subject "$subject"; then
      echo "ERROR: Relay alert delivery request failed" >&2
      return 1
    fi
    sent=$((sent + 1))
  done
  [[ "$sent" -gt 0 ]]
}

# Exercise this source's real transport without queries, repairs or state changes.
# The proof destination is fixed, irrespective of the configured recipients.
if [[ "${1:-}" == "--test-alert" ]]; then
  relay_alert dev@dtcdev.click "TEST dr-raise-stale-check Relay alert" "Controlled dr-raise-stale-check alert transport proof."
  exit $?
fi
STALE_SECONDS="${STALE_SECONDS:-691200}"  # 8 days
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
STATE_DIR="${STATE_DIR:-/var/lib/dr-raise-stale-check}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-1440}"  # once/day while still stale
DRY_RUN="${DRY_RUN:-0}"
if [[ "$DRY_RUN" != 1 ]]; then
  mkdir -p "$STATE_DIR"
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
NOW="$(date +%s)"

query_vm() {
  local expr="$1"
  curl -sS -m 10 --get "${VM_URL}/api/v1/query" --data-urlencode "query=${expr}" 2>/dev/null || true
}

send_alert() {
  local subject="$1" body="$2"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY_RUN would alert: ${subject} (no email/state changes)"
    return 0
  fi
  local state_file="${STATE_DIR}/stale.state"
  local last_alert=0 last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"
  fi
  local is_recovery=0
  [[ "$subject" == RECOVERED* ]] && is_recovery=1
  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    local elapsed_min=$(( (NOW - last_alert) / 60 ))
    if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
      log "dedupe: still FAIL, last alert ${elapsed_min}m ago"
      return 0
    fi
  fi
  local full_subject="[dr-fast-pg-raise] ${subject}"
  if ! relay_alert "$ALERT_TO" "$full_subject" "$body"; then
    log "ERROR alert request failed; dedupe state unchanged"
    return 1
  fi
  log "ALERT subject='${full_subject}' via=relay to=${ALERT_TO}"
  printf 'STATUS=%s\nLAST_ALERT=%s\n' "$([ "$is_recovery" -eq 1 ] && echo OK || echo FAIL)" \
    "$([ "$is_recovery" -eq 1 ] && echo 0 || echo "$NOW")" >"$state_file"
}

# Weekly push samples disappear from instant lookback between runs. Search the
# full stale window (8d by default), then take the newest success across hosts.
# This also keeps a 7-8 day old success valid until the existing 8d deadline.
AGE_JSON="$(query_vm "time() - max(max_over_time(dr_fast_pg_raise_last_success_unixtime[${STALE_SECONDS}s]))")"
AGE="$(python3 - <<'PY' "$AGE_JSON" 2>/dev/null || true
import json,sys
try:
  d=json.loads(sys.argv[1])
  r=d.get("data",{}).get("result") or []
  if not r:
    print("MISSING"); raise SystemExit
  print(r[0]["value"][1])
except Exception:
  print("MISSING")
PY
)"

if [[ "$AGE" == "MISSING" || -z "$AGE" ]]; then
  log "FAIL: last_success metric missing/unreadable"
  send_alert "FAIL stale/missing weekly raise" \
    "dr_fast_pg_raise_last_success_unixtime missing in VictoriaMetrics at ${VM_URL}.
Weekly Contabo→alt-host fast PG raise has no successful run recorded.
Schedule: Sundays 04:30 Europe/Berlin on Hetzner (contingency/weekly-fast-pg-raise.sh).
Alert destination: ${ALERT_TO}."
  exit 1
fi

# AGE may be float
AGE_INT="$(printf '%.0f' "$AGE" 2>/dev/null || echo 999999999)"
if [[ "$AGE_INT" -gt "$STALE_SECONDS" ]]; then
  DAYS="$(python3 -c "print(round($AGE_INT/86400, 2))" 2>/dev/null || echo "?")"
  log "FAIL: last_success age=${AGE_INT}s (~${DAYS}d) > ${STALE_SECONDS}"
  send_alert "FAIL no successful raise within 8 days" \
    "dr_fast_pg_raise_last_success_unixtime is ${AGE_INT}s old (~${DAYS} days; threshold ${STALE_SECONDS}s).
Weekly Contabo→alt-host fast PG raise missed its window.
vmui: ${VM_URL}/vmui
Alert destination: ${ALERT_TO}."
  exit 1
fi

log "OK last_success age=${AGE_INT}s (threshold ${STALE_SECONDS})"
if [[ "$DRY_RUN" == 1 ]]; then
  log "DRY_RUN no email/state changes"
  exit 0
fi
state_file="${STATE_DIR}/stale.state"
last_status=""
if [[ -f "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file" || true
  last_status="${STATUS:-}"
fi
if [[ "$last_status" == "FAIL" ]]; then
  send_alert "RECOVERED weekly raise fresh" \
    "last_success age=${AGE_INT}s is within ${STALE_SECONDS}s again."
else
  printf 'STATUS=OK\nLAST_ALERT=%s\n' "${LAST_ALERT:-0}" >"$state_file"
fi
exit 0
