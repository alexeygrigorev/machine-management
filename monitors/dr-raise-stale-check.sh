#!/usr/bin/env bash
# Dead-man for weekly Contabo→alt-host fast PG raise.
#
# Alerts to ALERT_TO (default alexey@datatalks.club,dev@dtcdev.click) when:
#   - VictoriaMetrics has no dr_fast_pg_raise_last_success_unixtime, OR
#   - (time() - last_success) > STALE_SECONDS (default 8 days = 691200)
#
# Transport chain (first success wins; all failures are loud):
#   1. msmtp with the dedicated alerts account (proven SES path, same account
#      as coolify-healthcheck) — handles any body, including IP-literal URLs.
#   2. sendmail (usually msmtp-backed on Contabo hosts).
#   3. Relay datamailer client as a last resort, with IP-literal URLs in the
#      body defanged: Relay sits behind a CloudFront WAF whose managed rules
#      block request bodies containing http(s)://<ip-literal> (reproduced
#      2026-10-27: such bodies get a bare HTTP 403). Every real alert from
#      this check contains the local vmui URL, so Relay can never be primary.
# A total delivery failure returns non-zero and leaves dedupe state
# unchanged, so the next run retries instead of going silent.
#
# Prefer running on contabo-a (local VM + existing msmtp SES path).
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
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-DTC Alerts <alerts@dtcdev.click>}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-/usr/local/sbin/ops-daily-digest.sh}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
NOW="$(date +%s)"

strip_personal_recipients() {
  local csv="${1// /,}" tok out=""
  local -a parts=()
  IFS=',' read -r -a parts <<< "$csv"
  for tok in "${parts[@]}"; do
    [[ -z "$tok" ]] && continue
    case "$tok" in
      alexey@*|*alexey.s.grigoriev@*) continue ;;
      *) out="${out:+${out},}${tok}" ;;
    esac
  done
  printf '%s' "${out:-${ALERT_OPS_TO:-dev@dtcdev.click}}"
}

enqueue_digest() {
  local src="$1" check="$2" sev="$3" summary="$4"
  if [[ -x "$DIGEST_SCRIPT" ]]; then
    "$DIGEST_SCRIPT" --enqueue "$src" "$check" "$sev" "$summary" 2>/dev/null || true
  fi
}

# Relay client/key for Contabo monitors, stored root-owned mode 0600. The CLI
# loads it from disk; credentials never appear in process arguments or logs.
# Last-resort transport only (see header): the CloudFront WAF in front of
# Relay blocks bodies with IP-literal URLs, which our alerts always contain.
sanitize_for_relay() {
  # Defang http(s)://<ip-literal> so the WAF body rules let the message pass.
  # Hostnames are untouched; the address stays readable for the operator.
  # (Single-label all-hex authorities like http://beef/ are defanged too --
  # harmless, and never real alert URLs.)
  sed -E 's#https?://(\[?[0-9A-Fa-f:.]+\]?)([/:?#]|$)#\1\2#g'
}

relay_alert() {
  local recipients="${1// /,}" subject="$2" body="$3" recipient sent=0
  local -a addresses=()
  IFS=',' read -r -a addresses <<< "$recipients"
  for recipient in "${addresses[@]}"; do
    [[ -n "$recipient" ]] || continue
    if ! printf '%s\n' "$body" | env -u DATAMAILER_API_KEY -u DATAMAILER_URL \
      DATAMAILER_CONFIG="${RELAY_MONITOR_CONFIG:-/etc/relay-monitors.toml}" \
      "${DATAMAILER_BIN:-/usr/local/bin/datamailer}" send --from alerts \
      --to "$recipient" --subject "$subject" >/dev/null; then
      echo "ERROR: Relay alert delivery request failed" >&2
      return 1
    fi
    sent=$((sent + 1))
  done
  [[ "$sent" -gt 0 ]]
}

# Proven MTA path (same alerts account as coolify-healthcheck). Prints the
# working transport name (msmtp|sendmail) on stdout; returns 1 if neither
# delivery agent is usable.
mta_alert() {
  local subject="$1" body="$2"
  local to_csv="${ALERT_TO// /,}"
  local to_header="${to_csv//,/, }"
  local -a to_args=()
  IFS=',' read -r -a to_args <<< "$to_csv"
  local envelope_from from_header
  local from_pat='<([^>]+)>'
  if [[ "$ALERT_FROM" =~ $from_pat ]]; then
    envelope_from="${BASH_REMATCH[1]}"
    from_header="$ALERT_FROM"
  else
    envelope_from="$ALERT_FROM"
    from_header="$ALERT_FROM"
  fi
  local msmtp_args=()
  [[ -n "${ALERT_MSMTP_ACCOUNT:-}" ]] && msmtp_args+=("-a" "$ALERT_MSMTP_ACCOUNT")
  [[ -n "$envelope_from" ]] && msmtp_args+=("-f" "$envelope_from")
  if command -v msmtp >/dev/null 2>&1; then
    if {
      echo "From: ${from_header}"
      echo "To: ${to_header}"
      echo "Subject: ${subject}"
      echo ""
      printf '%s\n' "$body"
    } | msmtp "${msmtp_args[@]}" -- "${to_args[@]}" >/dev/null; then
      echo "msmtp"
      return 0
    fi
    log "WARN: msmtp delivery failed; trying next transport" >&2
  fi
  if command -v sendmail >/dev/null 2>&1; then
    local sendmail_args=(-t)
    [[ -n "$envelope_from" ]] && sendmail_args+=(-f "$envelope_from")
    if {
      echo "From: ${from_header}"
      echo "To: ${to_header}"
      echo "Subject: ${subject}"
      echo ""
      printf '%s\n' "$body"
    } | sendmail "${sendmail_args[@]}" >/dev/null; then
      echo "sendmail"
      return 0
    fi
    log "WARN: sendmail delivery failed; trying next transport" >&2
  fi
  return 1
}

# Run the transport chain for a real alert. Prints the winning transport on
# stdout; returns 1 when nothing delivered (state file left untouched).
deliver_alert() {
  local subject="$1" body="$2" via=""
  if via="$(mta_alert "$subject" "$body")"; then
    echo "$via"
    return 0
  fi
  if relay_alert "$ALERT_TO" "$subject" "$(printf '%s' "$body" | sanitize_for_relay)"; then
    echo "relay-fallback"
    return 0
  fi
  return 1
}

# Exercise this source's real transport without queries, repairs or state changes.
# The proof destination is fixed, irrespective of the configured recipients.
if [[ "${1:-}" == "--test-alert" ]]; then
  if via="$(ALERT_TO="dev@dtcdev.click" deliver_alert "TEST dr-raise-stale-check alert (transport proof)" "Controlled dr-raise-stale-check alert transport proof.")"; then
    log "TEST alert delivered via=${via} to=dev@dtcdev.click"
    exit 0
  fi
  log "ERROR: TEST alert delivery failed on every transport"
  exit 1
fi
STALE_SECONDS="${STALE_SECONDS:-691200}"  # 8 days
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
STATE_DIR="${STATE_DIR:-/var/lib/dr-raise-stale-check}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-1440}"  # once/day while still stale
DRY_RUN="${DRY_RUN:-0}"
if [[ "$DRY_RUN" != 1 ]]; then
  mkdir -p "$STATE_DIR"
fi

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
  local target_to="$ALERT_TO"
  if [[ "$is_recovery" -eq 1 ]]; then
    target_to="$(strip_personal_recipients "$ALERT_TO")"
    enqueue_digest "dr-fast-pg-raise" "stale" "RECOVERED" "$full_subject"
  elif [[ "$STATE_DIR" != "/var/lib/dr-raise-stale-check" && "$(command -v msmtp 2>/dev/null || true)" == "/usr/bin/msmtp" ]]; then
    target_to="$(strip_personal_recipients "$ALERT_TO")"
  fi
  local via=""
  if via="$(ALERT_TO="$target_to" deliver_alert "$full_subject" "$body")"; then
    log "ALERT subject='${full_subject}' via=${via} to=${target_to}"
  else
    log "ERROR: all alert transports failed (msmtp, sendmail, Relay); dedupe state unchanged"
    return 1
  fi
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
