#!/usr/bin/env bash
# One incident = one FAIL mail + one RECOVERED mail (Alexey t2813u/t2814u).
# Sourced by coolify-healthcheck.sh and contabo-deadman.sh. Callers provide
# STATE_DIR, NOW (epoch seconds) and log(); this file only decides, it never
# sends mail itself.
#
# Policy
#  * Checks are grouped by service (relay, cmp, aisl, website, ...). The first
#    FAIL of any check in a service opens an incident and is paged at once
#    (fail-loud). Every further FAIL of a sibling check is logged, not mailed.
#  * RECOVERED goes out only when every failing check of the service has been
#    green for INCIDENT_GREEN_SEC (5 min). A re-FAIL inside that window is the
#    same incident: no new FAIL mail.
#  * After RECOVERED, a new FAIL inside INCIDENT_FLAP_WINDOW_SEC (15 min) is
#    held until it has lasted INCIDENT_FLAP_CONFIRM_SEC (5 min), then paged
#    once, so a flapping endpoint never yields FAIL/RECOVERED/FAIL/RECOVERED.
#  * dev/staging checks never mail: log + one DataOps task per incident.

INCIDENT_GREEN_SEC="${INCIDENT_GREEN_SEC:-300}"
INCIDENT_FLAP_WINDOW_SEC="${INCIDENT_FLAP_WINDOW_SEC:-900}"
INCIDENT_FLAP_CONFIRM_SEC="${INCIDENT_FLAP_CONFIRM_SEC:-300}"

# incident_class <check-name> -> "dev" | "prod"
incident_class() {
  local n="${1,,}"
  case "$n" in
    *_dev|*-dev|*_dev_*|*-dev-*|*dev.*|*_staging|*-staging|*_stage|*-stage) echo dev ;;
    *) echo prod ;;
  esac
}

# incident_service <check-name> -> service key. Strips the check-type prefix and
# any dev/staging suffix, then folds aliases of the same service together.
incident_service() {
  local n="${1,,}"
  case "$n" in node-*) echo contabo; return ;; esac   # both Contabo nodes = one provider incident
  n="${n#http-}"; n="${n#content-}"; n="${n#latency-}"; n="${n#probe-}"; n="${n#ext-}"
  n="${n%_dev}"; n="${n%-dev}"; n="${n%_staging}"; n="${n%-staging}"
  case "$n" in
    relay*) echo relay ;;
    courses*|cmp*) echo cmp ;;
    aishl*|aisl*) echo aisl ;;
    website*|prod_datatalks*) echo website ;;
    *) echo "$n" ;;
  esac
}

_incident_file() { printf '%s/svc-%s.incident' "$STATE_DIR" "$1"; }

_incident_load() { # $1=svc ; sets I_* vars
  I_OPEN=0 I_OPEN_SINCE=0 I_MAILED_AT=0 I_FAILING="" I_GREEN_SINCE=0 I_RECOVERED_AT=0 I_PENDING_SINCE=0
  local f; f="$(_incident_file "$1")"
  # shellcheck disable=SC1090
  [[ -f "$f" ]] && source "$f" || true
  I_OPEN="${OPEN:-0}" I_OPEN_SINCE="${OPEN_SINCE:-0}" I_MAILED_AT="${MAILED_AT:-0}"
  I_FAILING="${FAILING:-}" I_GREEN_SINCE="${GREEN_SINCE:-0}"
  I_RECOVERED_AT="${RECOVERED_AT:-0}" I_PENDING_SINCE="${PENDING_SINCE:-0}"
  unset OPEN OPEN_SINCE MAILED_AT FAILING GREEN_SINCE RECOVERED_AT PENDING_SINCE
}

_incident_save() { # $1=svc
  mkdir -p "$STATE_DIR"
  printf 'OPEN=%s\nOPEN_SINCE=%s\nMAILED_AT=%s\nFAILING="%s"\nGREEN_SINCE=%s\nRECOVERED_AT=%s\nPENDING_SINCE=%s\n' \
    "$I_OPEN" "$I_OPEN_SINCE" "$I_MAILED_AT" "$I_FAILING" "$I_GREEN_SINCE" "$I_RECOVERED_AT" "$I_PENDING_SINCE" \
    > "$(_incident_file "$1")"
}

_incident_has() { [[ " $I_FAILING " == *" $2 "* ]]; }

# incident_fail <svc> <check> -> echoes send | hold
incident_fail() {
  local svc="$1" chk="$2" verdict=hold
  _incident_load "$svc"
  _incident_has "$svc" "$chk" || I_FAILING="${I_FAILING:+$I_FAILING }$chk"
  I_GREEN_SINCE=0
  if [[ "$I_OPEN" == 1 ]]; then
    # Same incident. Only the periodic repeat reminder may mail again.
    if [[ "$I_MAILED_AT" -gt 0 && $(( NOW - I_MAILED_AT )) -ge $(( ${ALERT_REPEAT_MIN:-60} * 60 )) ]]; then
      verdict=send; I_MAILED_AT="$NOW"
    fi
  elif [[ "$I_RECOVERED_AT" -gt 0 && $(( NOW - I_RECOVERED_AT )) -lt "$INCIDENT_FLAP_WINDOW_SEC" ]]; then
    # Flapping right after a RECOVERED: page only if it persists.
    [[ "$I_PENDING_SINCE" -gt 0 ]] || I_PENDING_SINCE="$NOW"
    if [[ $(( NOW - I_PENDING_SINCE )) -ge "$INCIDENT_FLAP_CONFIRM_SEC" ]]; then
      verdict=send; I_OPEN=1; I_OPEN_SINCE="$I_PENDING_SINCE"; I_MAILED_AT="$NOW"; I_PENDING_SINCE=0
    fi
  else
    verdict=send; I_OPEN=1; I_OPEN_SINCE="$NOW"; I_MAILED_AT="$NOW"; I_PENDING_SINCE=0
  fi
  _incident_save "$svc"
  echo "$verdict"
}

# incident_green <svc> <check> -> echoes recover | hold | none
#   recover: caller must send the single RECOVERED mail for the service.
incident_green() {
  local svc="$1" chk="$2" verdict=none f
  f="$(_incident_file "$svc")"
  [[ -f "$f" ]] || { echo none; return; }
  _incident_load "$svc"
  local rest="" t
  for t in $I_FAILING; do [[ "$t" == "$chk" ]] || rest="${rest:+$rest }$t"; done
  I_FAILING="$rest"
  if [[ -z "$I_FAILING" ]]; then
    if [[ "$I_OPEN" == 1 ]]; then
      [[ "$I_GREEN_SINCE" -gt 0 ]] || I_GREEN_SINCE="$NOW"
      if [[ $(( NOW - I_GREEN_SINCE )) -ge "$INCIDENT_GREEN_SEC" ]]; then
        verdict=recover; I_OPEN=0; I_RECOVERED_AT="$NOW"; I_GREEN_SINCE=0
      else
        verdict=hold
      fi
    else
      I_PENDING_SINCE=0   # a held flap went green again: never paged, stays silent
    fi
  fi
  _incident_save "$svc"
  echo "$verdict"
}

# incident_open_since <svc> -> epoch the open incident started (0 if none)
incident_open_since() { _incident_load "$1"; echo "$I_OPEN_SINCE"; }

# incident_dev_note <check> <level> <message>: dev/staging never mail. Log, and
# open one DataOps task per incident (best effort; the log line is the record).
incident_dev_note() {
  local chk="$1" lvl="$2" msg="$3" svc f
  svc="$(incident_service "$chk")"
  f="$STATE_DIR/dev-${svc}.task"
  log "DEV-ALERT check=${chk} level=${lvl}: ${msg} (no mail; dev/staging)"
  [[ "$lvl" == FAIL ]] || { [[ "$lvl" == RECOVERED ]] && rm -f "$f"; return 0; }
  [[ -f "$f" ]] && return 0
  : > "$f"
  if [[ -n "${INCIDENT_TASK_CMD:-}" ]]; then
    # shellcheck disable=SC2086
    $INCIDENT_TASK_CMD "dev alert ${chk}: ${msg}" >/dev/null 2>&1 \
      || log "WARN dev-alert task create failed for ${chk}; log line above is the record"
  elif command -v dataops >/dev/null 2>&1; then
    dataops tasks create --description "dev alert ${chk}: ${msg}" --tags dev-alert >/dev/null 2>&1 \
      || log "WARN dev-alert DataOps task create failed for ${chk}; log line above is the record"
  fi
}
