#!/usr/bin/env bash
# Regression check: page dev@ when coolify-proxy is missing a network that a
# routed app uses (2026-10-25 relay-dev/cmp-dev proxy-detach incident).
#
# Runs ON each Contabo node as a frequent cron job (see
# coolify-proxy-networks.cron: every 5 min Europe/Berlin). The self-healer is
# edge/ensure-coolify-proxy-networks.sh --apply (every 2 min cron); THIS
# script changes nothing — it only verifies and pages when the proxy is still
# detached (e.g. the healer failed, cron died, or a brand-new service network
# appeared). Discovery rule is identical to the healer: every RUNNING
# container with traefik.enable=true and a non-coolify traefik.docker.network
# label must share that network with the coolify-proxy container.
#
# Alerting: dev@dtcdev.click ONLY (never Alexey directly), same rules as the
# main healthcheck — one FAIL mail per missing set, repeat at most every
# ALERT_REPEAT_MIN while still failing, RECOVERED on green again.
# No secrets: only network/container names enter mail (names are Coolify
# uuids, not credentials). Exit 0 when attached, 1 when detached.
set -euo pipefail

ENV_FILE="${COOLIFY_PROXY_NETWORKS_ENV_FILE:-/etc/coolify-proxy-networks.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

STATE_DIR="${STATE_DIR:-/var/lib/coolify-proxy-networks}"
# Old env files pointed at the main check's pruned namespace. Keep those safe
# even before reinstalling; prune_stale_checks only scans direct *.state files.
if [[ "${STATE_DIR%/}" == /var/lib/coolify-healthcheck ]]; then
  STATE_DIR="${STATE_DIR%/}/proxy-networks"
fi
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-proxy-networks.lock}"
LOG_FILE="${LOG_FILE:-/var/log/coolify-healthcheck.log}"
PROXY_CONTAINER="${PROXY_CONTAINER:-coolify-proxy}"
ALERT_TO="${ALERT_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_SUBJECT_PREFIX="${ALERT_SUBJECT_PREFIX:-[coolify-proxy-networks]}"
[[ "$ALERT_TO" == dev@dtcdev.click ]] || { log "ERROR: proxy-network alerts must go to dev@ only"; exit 1; }
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"
RECOVER_NOTIFY_MIN_SEC="${RECOVER_NOTIFY_MIN_SEC:-600}"

command -v docker >/dev/null 2>&1 || { log "ERROR: missing required binary: docker"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log "ERROR: missing required binary: python3"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "ERROR: missing required binary: flock"; exit 1; }

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another proxy-networks check is running (lock: $LOCK_FILE); skipping"; exit 0; }

FAILED=0
NOW="$(date +%s)"

send_alert() {
  # $1=check-name $2=subject-suffix $3=body (same dedupe/recover as healthcheck)
  local name="$1" subject="$2" body="$3"
  local state_file="${STATE_DIR}/${name}.state"
  local last_alert=0 last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"
    FAIL_SINCE="${FAIL_SINCE:-0}"
  fi
  local is_recovery=0
  [[ "$subject" == RECOVERED* ]] && is_recovery=1
  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    local elapsed_min=$(( (NOW - last_alert) / 60 ))
    if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
      return 0
    fi
  fi
  local full_subject="${ALERT_SUBJECT_PREFIX} ${subject} (${name})"
  local sent="no"
  local to_csv="${ALERT_TO// /,}"
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
    log "WARN: no MTA (sendmail/msmtp) on this host — alert for ${name} logged only; install msmtp and configure SMTP (see README)"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${ALERT_TO}"
  # Failed transport must retry next run, including a failed recovery.
  [[ "$sent" != no ]] || return 0
  if [[ "$is_recovery" -eq 1 ]]; then
    printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\n' > "$state_file"
  else
    local fail_since="${FAIL_SINCE:-$NOW}"
    if [[ "${last_status:-}" != "FAIL" || -z "${FAIL_SINCE:-}" || "${FAIL_SINCE:-0}" -eq 0 ]]; then
      fail_since="$NOW"
    fi
    printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\n' "$NOW" "$fail_since" > "$state_file"
  fi
}

mark_ok() {
  # $1=check-name — sends RECOVERED if previous state was FAIL AND the outage
  # lasted at least RECOVER_NOTIFY_MIN_SEC (t1273u: mute rapid recover spam).
  # Short flaps still leave STATUS=OK silently; FAIL already paged if it fired.
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status="" fail_since=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    local dur=0
    if [[ "$fail_since" =~ ^[0-9]+$ && "$fail_since" -gt 0 ]]; then
      dur=$(( NOW - fail_since ))
    fi
    if [[ "$dur" -ge "$RECOVER_NOTIFY_MIN_SEC" ]]; then
      send_alert "$name" "RECOVERED" "Check '${name}' is green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ') (was FAIL for ${dur}s)."
    else
      log "OK check=${name}: recovered after ${dur}s (< RECOVER_NOTIFY_MIN_SEC=${RECOVER_NOTIFY_MIN_SEC}) — suppressing RECOVERED mail"
      printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\n' > "$state_file"
    fi
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\nFAIL_SINCE=0\n' "${LAST_ALERT:-0}" > "$state_file"
  fi
}

NAME="proxy-networks"
if ! docker inspect "$PROXY_CONTAINER" >/dev/null 2>&1; then
  log "FAIL check=${NAME}: proxy container ${PROXY_CONTAINER} not found on $(hostname)"
  send_alert "$NAME" "FAIL" "coolify-proxy container '${PROXY_CONTAINER}' not found on $(hostname) — Traefik may be down; all routed apps on this host are affected."
  exit 1
fi

proxy_nets="$(docker inspect "$PROXY_CONTAINER" 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(" ".join(sorted(d.get("NetworkSettings",{}).get("Networks",{}).keys())))' 2>/dev/null || true)"
if [[ -z "$proxy_nets" ]]; then
  log "FAIL check=${NAME}: cannot read proxy networks (docker inspect parse failed)"
  send_alert "$NAME" "FAIL" "Cannot read networks of '${PROXY_CONTAINER}' on $(hostname) — docker inspect parse failed."
  exit 1
fi

missing=""
routed=0
for c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
  en="$(docker inspect --format '{{index .Config.Labels "traefik.enable"}}' "$c" 2>/dev/null || true)"
  [[ "$en" == "true" ]] || continue
  routed=$((routed+1))
  want="$(docker inspect --format '{{index .Config.Labels "traefik.docker.network"}}' "$c" 2>/dev/null || true)"
  case "$want" in ""|"<no value>"*|*" <no value>"*|coolify|bridge|host|none) continue ;; esac
  docker network inspect "$want" >/dev/null 2>&1 || { log "WARN: routed $c wants missing network $want — skipping"; continue; }
  case " $proxy_nets " in
    *" $want "*) ;;
    *) missing="$missing $want($c)" ;;
  esac
done

if [[ -n "${missing// /}" ]]; then
  log "FAIL check=${NAME}: proxy ${PROXY_CONTAINER} nets=[$proxy_nets] missing:${missing} (routed containers: $routed)"
  send_alert "$NAME" "FAIL" "coolify-proxy on $(hostname) is missing service network(s):${missing}. Proxy nets: [$proxy_nets]. Routed containers checked: $routed. Traefik blackholes those backends until the keeper reattaches (edge/ensure-coolify-proxy-networks.sh --apply) — inspect /var/log/coolify-proxy-networks.log."
  FAILED=1
else
  log "OK check=${NAME}: proxy nets=[$proxy_nets] cover all routed service networks (routed: $routed)"
  mark_ok "$NAME"
fi

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
