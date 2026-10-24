#!/usr/bin/env bash
# Independent off-Contabo dead-man for the Contabo fleet (t1143u R14/SO-07).
#
# Runs on HETZNER (or any off-Contabo operator box) as a user cron job
# (see contabo-deadman.cron) — never on the Contabo hosts it watches.
# This is the monitor of last resort: if both Contabo nodes go dark, the
# on-node healthchecks die with them, and THIS script is what pages humans.
#
# What it checks:
#   1. Reachability + check freshness per node (DEADMAN_HOSTS): SSH in and
#      read the last completed healthcheck run. FAILs only when the node is
#      unreachable or its checks stopped advancing (stale/missing log).
#      A node that is alive but reporting FAIL stays the on-node healthcheck's
#      job — the dead-man does not double-page its content.
#   2. External content probes (DEADMAN_URLS, name=url::marker triples, same
#      match semantics as coolify-healthcheck.sh CONTENT_CHECKS): 2xx/3xx AND
#      a verbatim body marker, fetched from THIS box — an off-Contabo vantage
#      no Contabo outage can silence.
#
# Fault drill (safe, no production impact): run once with
#   DEADMAN_FORCE_FAIL=1 ./monitors/contabo-deadman.sh
# to prove the Hetzner mail path end to end (one FAIL mail), then run again
# normally to get the RECOVERED mail. Never blocks real checks.
#
# Secrets: NEVER in git. SMTP lives in ~/.msmtprc (root/user-only 600),
# built privately from ~/.secrets (see install-contabo-deadman.sh notes).
# Exit code: 0 if every check passed, 1 if any check failed.
set -euo pipefail

ENV_FILE="${CONTABO_DEADMAN_ENV_FILE:-$HOME/.contabo-deadman.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- config (overridable via env file) ----
STATE_DIR="${STATE_DIR:-$HOME/.local/state/contabo-deadman}"
LOCK_FILE="${LOCK_FILE:-$HOME/.local/state/contabo-deadman.lock}"
LOG_FILE="${LOG_FILE:-$HOME/.local/state/contabo-deadman/cron.log}"
# Space-separated SSH targets, e.g. "contabo-a contabo-b".
DEADMAN_HOSTS="${DEADMAN_HOSTS:-contabo-a contabo-b}"
DEADMAN_SSH_TIMEOUT="${DEADMAN_SSH_TIMEOUT:-10}"
# Remote healthcheck log; only ALL_OK/CHECKS_FAILED prove a completed run.
DEADMAN_REMOTE_LOG="${DEADMAN_REMOTE_LOG:-/var/log/coolify-healthcheck.log}"
# Alert if no completed run falls within this long (5-min on-node
# cadence + skew margin).
DEADMAN_MAX_LOG_AGE_SEC="${DEADMAN_MAX_LOG_AGE_SEC:-600}"
# External content probes, name=url::marker (lowercase, no whitespace;
# body is lowercased + whitespace-stripped before fixed-string match).
DEADMAN_URLS="${DEADMAN_URLS:-courses_api=https://courses.datatalks.club/api/health/::\"status\":\"ok\" website_ready=https://prod.datatalks.club/health/ready::\"status\":\"ready\" relay_health=https://relay.datatalks.club/health/::\"service\":\"relay\"}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
DEADMAN_FORCE_FAIL="${DEADMAN_FORCE_FAIL:-0}"

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
# Drills (DEADMAN_FORCE_FAIL) page ops only — never Alexey (t1273u/t1274u).
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"

command -v ssh >/dev/null 2>&1 || { log "ERROR: missing required binary: ssh"; exit 1; }
command -v curl >/dev/null 2>&1 || { log "ERROR: missing required binary: curl"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "ERROR: missing required binary: flock"; exit 1; }
command -v timeout >/dev/null 2>&1 || { log "ERROR: missing required binary: timeout"; exit 1; }

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another dead-man run is in progress (lock: $LOCK_FILE); skipping"; exit 0; }

FAILED=0
NOW="$(date +%s)"

send_alert() {
  # $1=check-name $2=subject-suffix $3=body [$4=optional to-csv override]
  # Drill path passes ALERT_OPS_TO so FORCE_FAIL never pages alexey@ (t1273u).
  local name="$1" subject="$2" body="$3"
  local to_override="${4:-}"
  local state_file="${STATE_DIR}/${name}.state"
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
      return 0
    fi
  fi
  local full_subject="[contabo-deadman] ${subject} (${name})"
  local sent="no"
  local to_csv
  if [[ -n "$to_override" ]]; then
    to_csv="${to_override// /,}"
  else
    to_csv="${ALERT_TO// /,}"
  fi
  local to_header="${to_csv//,/, }"
  local -a to_args=()
  IFS=',' read -r -a to_args <<< "$to_csv"

  local envelope_from from_header
  local from_pat='<([^>]+)>'
  if [[ "$ALERT_FROM" =~ $from_pat ]]; then
    envelope_from="${BASH_REMATCH[1]}"
    from_header="$ALERT_FROM"
  elif [[ -n "${ALERT_FROM_NAME:-}" ]]; then
    envelope_from="$ALERT_FROM"
    from_header="${ALERT_FROM_NAME} <${ALERT_FROM}>"
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
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | msmtp "${msmtp_args[@]}" -- "${to_args[@]}" 2>/dev/null; then
      sent="msmtp"
    else
      log "WARN: msmtp failed for ${name}"
    fi
  elif command -v sendmail >/dev/null 2>&1; then
    local sendmail_args=("-t")
    local sendmail_bin
    sendmail_bin="$(command -v sendmail)"
    if [[ "$(readlink -f "$sendmail_bin" 2>/dev/null || echo "$sendmail_bin")" == *msmtp* ]]; then
      [[ -n "${ALERT_MSMTP_ACCOUNT:-}" ]] && sendmail_args+=("-a" "$ALERT_MSMTP_ACCOUNT")
    fi
    [[ -n "$envelope_from" ]] && sendmail_args+=("-f" "$envelope_from")
    if {
      echo "From: ${from_header}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | sendmail "${sendmail_args[@]}" 2>/dev/null; then
      sent="sendmail"
    else
      log "WARN: sendmail failed for ${name}"
    fi
  else
    log "WARN: no MTA (sendmail/msmtp) on this host — alert for ${name} logged only; install msmtp (see install-contabo-deadman.sh)"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${to_csv}"
  # A failed delivery must retry next run, including a failed recovery mail.
  # Keep the previously delivered state rather than starting the dedupe timer.
  if [[ "$sent" == "no" ]]; then
    log "FAIL check=mail-${name}: delivery failed; retaining state for retry"
    FAILED=1
    return 0
  fi
  printf 'STATUS=%s\nLAST_ALERT=%s\n' "$([ "$is_recovery" -eq 1 ] && echo OK || echo FAIL)" \
    "$([ "$is_recovery" -eq 1 ] && echo 0 || echo "$NOW")" > "$state_file"
}

mark_ok() {
  # $1=check-name — sends RECOVERED if previous state was FAIL
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    send_alert "$name" "RECOVERED" "Check '${name}' is green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ')."
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\n' "${LAST_ALERT:-0}" > "$state_file"
  fi
}

mark_ok_ops() {
  # Like mark_ok but RECOVERED goes to ALERT_OPS_TO only (drills).
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    send_alert "$name" "RECOVERED" "Check '${name}' is green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ')." "$ALERT_OPS_TO"
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\n' "${LAST_ALERT:-0}" > "$state_file"
  fi
}

check_node() {
  # $1=ssh target — reachability + on-node check freshness
  local name="node-${1}" host="$1" out rc last_line completed_at epoch age
  # Bound the entire SSH operation: ConnectTimeout alone cannot stop a
  # connected but hung remote command from holding our lock forever.
  out="$(timeout "$DEADMAN_SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$DEADMAN_SSH_TIMEOUT" "$host" \
    "tail -n 2000 '$DEADMAN_REMOTE_LOG' 2>/dev/null | grep -E ' (ALL_OK|CHECKS_FAILED)$' | tail -n 1" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "FAIL check=${name}: ssh unreachable (rc=${rc}): $(echo "$out" | head -c 200)"
    send_alert "$name" "FAIL" "Off-Contabo dead-man cannot SSH to ${host} (rc=${rc}): ${out} — node may be down or the network path broken. On-node checks cannot page while unreachable."
    FAILED=1; return
  fi
  last_line="${out##*$'\n'}"
  completed_at="${last_line%% *}"
  epoch="$(date -d "$completed_at" +%s 2>/dev/null || true)"
  if [[ ! "$completed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ || ! "$epoch" =~ ^[0-9]+$ || ! "$last_line" =~ \ (ALL_OK|CHECKS_FAILED)$ ]]; then
    log "FAIL check=${name}: completed run missing/unreadable"
    send_alert "$name" "FAIL" "Dead-man reached ${host} but no completed healthcheck run is readable in ${DEADMAN_REMOTE_LOG}."
    FAILED=1; return
  fi
  age=$(( $(date +%s) - epoch ))
  if [[ "$age" -gt "$DEADMAN_MAX_LOG_AGE_SEC" ]]; then
    log "FAIL check=${name}: on-node checks stale — completed run age ${age}s (> ${DEADMAN_MAX_LOG_AGE_SEC}s), last='${last_line:0:120}'"
    send_alert "$name" "FAIL" "On-node healthcheck on ${host} stopped completing: ${DEADMAN_REMOTE_LOG} last completed run age ${age}s (threshold ${DEADMAN_MAX_LOG_AGE_SEC}s). Cron may be dead or a check hung — the node is up but unwatched."
    FAILED=1; return
  fi
  log "OK check=${name}: reachable, checks fresh (completed run age ${age}s, last='${last_line:0:100}')"
  mark_ok "$name"
}

check_url() {
  # $1=name $2=url $3=marker
  local name="ext-${1}" url="$2" marker="$3" code rc body_file
  body_file="$(mktemp)" || { log "FAIL check=${name}: mktemp failed"; FAILED=1; return; }
  code="$(curl -sS -o "$body_file" -w '%{http_code}' --connect-timeout 5 --max-time "$HTTP_TIMEOUT" "$url" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "FAIL check=${name}: curl ${url}: rc=${rc} detail='$(echo "$code" | head -c 160)'"
    send_alert "$name" "FAIL" "External probe failed for '${1}' (${url}): curl rc=${rc}. Neither Contabo node could be confirmed from outside — possible provider/network outage."
    FAILED=1; rm -f "$body_file"; return
  fi
  if [[ ! "$code" =~ ^[23] ]]; then
    log "FAIL check=${name}: ${url} returned HTTP ${code} (want 2xx/3xx)"
    send_alert "$name" "FAIL" "External probe for '${1}' (${url}) returned status ${code}."
    FAILED=1; rm -f "$body_file"; return
  fi
  if tr '[:upper:]' '[:lower:]' < "$body_file" | tr -d '[:space:]' | grep -F -- "$marker" >/dev/null; then
    log "OK check=${name}: ${url} -> ${code} marker='${marker}'"
    mark_ok "$name"
  else
    log "FAIL check=${name}: ${url} -> ${code} but marker '${marker}' absent"
    send_alert "$name" "FAIL" "External probe for '${1}' (${url}) returned HTTP ${code} but the body lacks marker '${marker}'."
    FAILED=1
  fi
  rm -f "$body_file"
}

# ---- run ----
if [[ "$DEADMAN_FORCE_FAIL" == "1" ]]; then
  log "FAIL check=drill-forced: DEADMAN_FORCE_FAIL=1 (safe mail-path drill, no production impact; ops-only recipients)"
  send_alert "drill-forced" "FAIL" "Dead-man drill: forced failure to prove the Hetzner mail path. Re-run without DEADMAN_FORCE_FAIL=1 to restore green + RECOVERED notice. Recipients: ops-only (${ALERT_OPS_TO})." "$ALERT_OPS_TO"
  FAILED=1
else
  # Close out a previous drill with a RECOVERED notice on the next green run
  # (silent when no drill ever failed). Ops-only — never alexey@.
  mark_ok_ops "drill-forced"
fi

# shellcheck disable=SC2086
for host in $DEADMAN_HOSTS; do
  check_node "$host"
done

if [[ -n "${DEADMAN_URLS:-}" ]]; then
  # shellcheck disable=SC2086
  for entry in $DEADMAN_URLS; do
    app="${entry%%=*}"; rest="${entry#*=}"
    url="${rest%%::*}"; marker="${rest#*::}"
    if [[ -z "$app" || -z "$url" || -z "$marker" || "$url" == "$rest" || "$marker" == "$rest" ]]; then
      log "WARN: skipping malformed DEADMAN_URLS entry: ${entry} (want name=url::marker)"
      continue
    fi
    check_url "$app" "$url" "$marker"
  done
else
  log "WARN: DEADMAN_URLS is empty — no external probes configured"
fi

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
