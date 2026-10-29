#!/usr/bin/env bash
# Storagebox S3-mirror staleness dead-man (t1553u).
#
# Alerts when ~/storagebox/backups/s3/.last-sync is older than STALE_SECONDS
# (default 36h = 129600) or missing/unparseable. Same msmtp alerts path as
# coolify-healthcheck / hetzner-disk-check: dedicated `alerts` msmtp account
# via SES SMTP, From DTC Alerts <alerts@dtcdev.click>.
#
# Real findings page ALERT_TO (default alexey@datatalks.club,dev@dtcdev.click).
# Drills route to ALERT_OPS_TO (default dev@dtcdev.click) only.
#
# Env overrides (all optional):
#   STORAGEBOX_ROOT=~/storagebox/backups
#   LAST_SYNC_FILE=$STORAGEBOX_ROOT/s3/.last-sync
#   STALE_SECONDS=129600  (36h)
#   ALERT_TO, ALERT_OPS_TO, ALERT_FROM, ALERT_FROM_NAME, ALERT_MSMTP_ACCOUNT
#   STATE_DIR=~/.local/state/storagebox-sync
#   ALERT_REPEAT_MIN=240 (dedupe while still FAIL)
#   STORAGEBOX_NOW=<epoch> (tests only; production never sets it)
#   DRY_RUN=1 — evaluate + print what WOULD alert, send nothing, exit 2 on stale
#   STORAGEBOX_STALE_DRILL=1 — force a FAIL alert to ALERT_OPS_TO only
#     (proves the Hetzner mail path); re-run without it to clear.
#
# Cron: daily + after the 04:30 mirror (see storagebox-staleness-check.cron).
# Install: ./monitors/install-storagebox-staleness-check.sh (user cron, no root).
#
# No secrets in git: SMTP lives in ~/.msmtprc (0600), built privately.
set -euo pipefail

STORAGEBOX_ROOT="${STORAGEBOX_ROOT:-$HOME/storagebox/backups}"
LAST_SYNC_FILE="${LAST_SYNC_FILE:-$STORAGEBOX_ROOT/s3/.last-sync}"
STALE_SECONDS="${STALE_SECONDS:-129600}"
ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-240}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/storagebox-sync}"
DRY_RUN="${DRY_RUN:-0}"
STORAGEBOX_STALE_DRILL="${STORAGEBOX_STALE_DRILL:-0}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-/usr/local/sbin/ops-daily-digest.sh}"

mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
NOW="${STORAGEBOX_NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s)";; esac

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

send_to() {
  # $1=to_csv $2=subject $3=body
  local to_csv="$1" subject="$2" body="$3"
  local state_file="${STATE_DIR}/staleness.state"
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
      log "dedupe: still FAIL, last alert ${elapsed_min}m ago (< ${ALERT_REPEAT_MIN}m)"
      return 0
    fi
  fi
  local full_subject="[storagebox-staleness] ${subject}"
  if [[ "$is_recovery" -eq 1 || "$STORAGEBOX_STALE_DRILL" == "1" ]]; then
    to_csv="$(strip_personal_recipients "$to_csv")"
    [[ "$is_recovery" -eq 1 ]] && enqueue_digest "storagebox-staleness" "staleness" "RECOVERED" "$full_subject"
  elif [[ "$STATE_DIR" != "$HOME/.local/state/storagebox-sync" && "$(command -v msmtp 2>/dev/null || true)" == "/usr/bin/msmtp" ]]; then
    to_csv="$(strip_personal_recipients "$to_csv")"
  fi
  to_csv="${to_csv// /,}"
  local to_header="${to_csv//,/, }"
  local -a to_args=()
  IFS=',' read -r -a to_args <<< "$to_csv"
  local envelope_from="$ALERT_FROM"
  local from_header="${ALERT_FROM_NAME} <${ALERT_FROM}>"
  local msmtp_args=()
  [[ -n "${ALERT_MSMTP_ACCOUNT:-}" ]] && msmtp_args+=("-a" "$ALERT_MSMTP_ACCOUNT")
  [[ -n "$envelope_from" ]] && msmtp_args+=("-f" "$envelope_from")
  local sent="no"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN would-alert subject='${full_subject}' to=${to_csv} via=none"
    printf 'DRY_RUN subject=%s\nDRY_RUN to=%s\n' "$full_subject" "$to_csv"
    return 0
  fi
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
      log "WARN: msmtp failed (account ${ALERT_MSMTP_ACCOUNT})"
    fi
  elif command -v sendmail >/dev/null 2>&1; then
    if {
      echo "From: ${from_header}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | sendmail -t 2>/dev/null; then
      sent="sendmail"
    else
      log "WARN: sendmail failed"
    fi
  else
    log "WARN: no MTA (sendmail/msmtp) — alert logged only"
  fi
  log "ALERT subject='${full_subject}' via=${sent} to=${to_csv}"
  if [[ "$is_recovery" -eq 1 ]]; then
    if [[ "$sent" != "no" ]]; then
      printf 'STATUS=OK\nLAST_ALERT=0\n' > "$state_file"
    else
      log "WARN: RECOVERED mail failed to send — keeping FAIL state"
    fi
  else
    local new_last_alert="$NOW"
    if [[ "$sent" == "no" ]]; then new_last_alert="$last_alert"; fi
    printf 'STATUS=FAIL\nLAST_ALERT=%s\n' "$new_last_alert" > "$state_file"
  fi
}

if [[ "$STORAGEBOX_STALE_DRILL" == "1" ]]; then
  log "DRILL: forcing stale FAIL to ${ALERT_OPS_TO}"
  send_to "$ALERT_OPS_TO" "FAIL storagebox mirror stale (DRILL)" \
"DRILL ${NOW} from $(hostname): forced storagebox-staleness drill (STORAGEBOX_STALE_DRILL=1).
Proves the Hetzner msmtp alerts path to ${ALERT_OPS_TO}.
Re-run without STORAGEBOX_STALE_DRILL=1 to clear with RECOVERED."
  exit 1
fi

if [[ ! -f "$LAST_SYNC_FILE" ]]; then
  log "FAIL: missing ${LAST_SYNC_FILE} (no successful mirror yet)"
  send_to "$ALERT_TO" "FAIL storagebox mirror .last-sync missing" \
"Storagebox S3 mirror freshness marker is MISSING: ${LAST_SYNC_FILE}.
No successful storagebox-sync run has completed (or the file was deleted —
deletions are forbidden; investigate immediately).
Mirror root: ${STORAGEBOX_ROOT}
Threshold: ${STALE_SECONDS}s (36h default).
Alert destination: ${ALERT_TO}."
  exit 1
fi

LAST_SYNC_RAW="$(cat "$LAST_SYNC_FILE" 2>/dev/null || true)"
LAST_SYNC_EPOCH="$(date -d "$LAST_SYNC_RAW" +%s 2>/dev/null || echo MISSING)"
if [[ "$LAST_SYNC_EPOCH" == "MISSING" || -z "$LAST_SYNC_EPOCH" ]]; then
  log "FAIL: unparseable .last-sync content: ${LAST_SYNC_RAW}"
  send_to "$ALERT_TO" "FAIL storagebox mirror .last-sync unparseable" \
"Storagebox S3 mirror freshness marker is UNPARSEABLE: ${LAST_SYNC_FILE}
content: ${LAST_SYNC_RAW}
Mirror root: ${STORAGEBOX_ROOT}
Alert destination: ${ALERT_TO}."
  exit 1
fi

AGE=$(( NOW - LAST_SYNC_EPOCH ))
if [[ "$AGE" -lt 0 ]]; then
  log "FAIL: .last-sync is in the future: marker=${LAST_SYNC_RAW} (now=${NOW}, clock skew or tampering?)"
  send_to "$ALERT_TO" "FAIL storagebox mirror .last-sync in future" \
"Storagebox S3 mirror freshness marker is IN THE FUTURE: ${LAST_SYNC_FILE}
content: ${LAST_SYNC_RAW} (now epoch ${NOW}).
Check the Hetzner clock and investigate tampering — deletions are forbidden.
Mirror root: ${STORAGEBOX_ROOT}
Alert destination: ${ALERT_TO}."
  exit 1
fi
if [[ "$AGE" -gt "$STALE_SECONDS" ]]; then
  DAYS="$(python3 -c "print(round($AGE/86400, 2))" 2>/dev/null || echo "?")"
  log "FAIL: .last-sync age=${AGE}s (~${DAYS}d) > ${STALE_SECONDS}s; marker=${LAST_SYNC_RAW}"
  send_to "$ALERT_TO" "FAIL storagebox mirror stale ${AGE}s (~${DAYS}d)" \
"Storagebox S3 mirror is STALE: .last-sync=${LAST_SYNC_RAW} (age ${AGE}s ~${DAYS}d, threshold ${STALE_SECONDS}s).
Mirror root: ${STORAGEBOX_ROOT}
Sync log: ~/.local/state/storagebox-sync/storagebox-backup-sync.log
Cron: /etc/cron.d/storagebox-backup-sync (04:30 Europe/Berlin daily).
Alert destination: ${ALERT_TO}."
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN OK: .last-sync age=${AGE}s <= ${STALE_SECONDS}s (marker=${LAST_SYNC_RAW})"
  exit 0
fi

log "OK: storagebox mirror fresh (age=${AGE}s <= ${STALE_SECONDS}s; marker=${LAST_SYNC_RAW})"
STATE_FILE="${STATE_DIR}/staleness.state"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  if [[ "${STATUS:-}" == "FAIL" ]]; then
    send_to "$ALERT_TO" "RECOVERED storagebox mirror fresh" \
"Storagebox S3 mirror is fresh again: .last-sync=${LAST_SYNC_RAW} (age ${AGE}s).
Previous FAIL state cleared."
  else
    printf 'STATUS=OK\nLAST_ALERT=0\n' > "$STATE_FILE" || true
  fi
fi
exit 0
