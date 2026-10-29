#!/usr/bin/env bash
# Hetzner host-local real disk alerting (t1493u, intake 57cf5788).
#
# Runs on HETZNER (RMTHZ, agent host) as a USER cron job
# (see hetzner-disk-check.cron) — never on Contabo.
# Reuses the coolify-healthcheck send_alert/msmtp path (dedicated `alerts`
# msmtp account via SES SMTP, From: DTC Alerts <alerts@dtcdev.click>).
#
# What it checks, for every real mount in DISK_MOUNTS (default "/ /boot /data";
# tmpfs/overlay/squashfs excluded; sshfs storagebox mount reported only,
# never paged):
#   1. Space free: WARN when free <DISK_WARN_FREE_PCT (15), CRIT when
#      free <DISK_CRIT_FREE_PCT (8).
#   2. Inode free: WARN when free <INODE_WARN_FREE_PCT (10),
#      CRIT when free <INODE_CRIT_FREE_PCT (5).
#   3. Fill trend: least-squares trend from stored samples (last FILL_WINDOW_H=6h)
#      predicts fill within FILL_CRIT_H=24h, gated to reject one-off step
#      changes (bulk moves, retentions, re-mounts):
#        - no step in the window: the recent FILL_CONFIRM_WINDOW_H=1h window
#          must independently predict fill within FILL_CRIT_H;
#        - step in the window (single 5-min drop > max(2GiB, 0.5% size) and
#          >50% of the window total drop): the tail AFTER the last such drop
#          must independently predict fill within FILL_CRIT_H with at least
#          FILL_CONFIRM_MIN_SPAN_SEC span, else no page.
#      A step-then-flat pattern therefore never pages (tail is flat or too
#      short), while sustained growth (no step, both windows steep) still
#      pages, including growth that resumes after a step (tail steep).
#      Static space/inode thresholds below are unchanged by this gate.
#      DISK_NOW (epoch seconds) overrides the clock; used only by tests to
#      replay fixtures at fixed ticks.
#
# Alerting: real findings page ALERT_TO (default
# alexey@datatalks.club,dev@dtcdev.click). Drills route to ALERT_OPS_TO
# (default dev@dtcdev.click) only. Dedupe: one FAIL, then repeat at most
# every ALERT_REPEAT_MIN minutes (default 240 = 4h); one RECOVERED on
# transition back to OK (suppressed for sub-600s flaps, same as
# coolify-healthcheck). A persistent low-disk state keeps re-paging —
# it is never muted.
#
# Drill (safe, no production impact): run once with
#   DISK_DRILL=1 ./monitors/hetzner-disk-check.sh
# to prove the Hetzner mail path end to end (one FAIL mail to dev@ only
# with a timestamp), then run again normally to get the RECOVERED mail.
#
# Secrets: NEVER in git. SMTP lives in ~/.msmtprc (0600), built privately
# from ~/.secrets. Exit code: 0 if every check passed, 1 if any failed.
set -euo pipefail

ENV_FILE="${HETZNER_DISK_ENV_FILE:-$HOME/.hetzner-disk-check.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- config (overridable via env file) ----
STATE_DIR="${STATE_DIR:-$HOME/.local/state/hetzner-disk-check}"
LOCK_FILE="${LOCK_FILE:-$HOME/.local/state/hetzner-disk-check.lock}"
LOG_FILE="${LOG_FILE:-$HOME/.local/state/hetzner-disk-check/cron.log}"
SAMPLE_DIR="${SAMPLE_DIR:-$STATE_DIR/samples}"

DISK_MOUNTS="${DISK_MOUNTS:-/ /boot /data}"
DISK_WARN_FREE_PCT="${DISK_WARN_FREE_PCT:-15}"
DISK_WARN_RECOVER_PCT="${DISK_WARN_RECOVER_PCT:-17}"
DISK_CRIT_FREE_PCT="${DISK_CRIT_FREE_PCT:-8}"
DISK_CRIT_RECOVER_PCT="${DISK_CRIT_RECOVER_PCT:-10}"
INODE_WARN_FREE_PCT="${INODE_WARN_FREE_PCT:-10}"
INODE_WARN_RECOVER_PCT="${INODE_WARN_RECOVER_PCT:-12}"
INODE_CRIT_FREE_PCT="${INODE_CRIT_FREE_PCT:-5}"
INODE_CRIT_RECOVER_PCT="${INODE_CRIT_RECOVER_PCT:-7}"
DISK_BREACH_RUNS="${DISK_BREACH_RUNS:-2}"
FILL_WINDOW_H="${FILL_WINDOW_H:-6}"
FILL_CRIT_H="${FILL_CRIT_H:-24}"
FILL_PAGE_H="${FILL_PAGE_H:-6}"
FILL_MIN_SPAN_SEC="${FILL_MIN_SPAN_SEC:-1800}"
# Recent-window confirmation for the fill trend: must independently predict
# fill within FILL_CRIT_H, else the long-window slope is treated as a stale
# one-off step change and does not page.
FILL_CONFIRM_WINDOW_H="${FILL_CONFIRM_WINDOW_H:-1}"
FILL_CONFIRM_MIN_SPAN_SEC="${FILL_CONFIRM_MIN_SPAN_SEC:-1800}"

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-240}"
RECOVER_NOTIFY_MIN_SEC="${RECOVER_NOTIFY_MIN_SEC:-600}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ops-daily-digest.sh}"

DISK_DRILL="${DISK_DRILL:-0}"
DISK_DF_BIN="${DISK_DF_BIN:-df}"

# Strip personal alexey@ addresses for non-PAGE events (WARN, predict, RECOVERED, drills, or unisolated test runs).
strip_personal_recipients() {
  local raw="${1// /,}" tok
  local -a kept=()
  IFS=',' read -r -a parts <<< "$raw"
  for tok in "${parts[@]}"; do
    [[ -n "$tok" ]] || continue
    case "${tok,,}" in
      alexey@*|*alexey.s.grigoriev@*) continue ;;
      *) kept+=("$tok") ;;
    esac
  done
  if [[ "${#kept[@]}" -eq 0 ]]; then
    echo "${ALERT_OPS_TO:-dev@dtcdev.click}"
  else
    local IFS=','
    echo "${kept[*]}"
  fi
}

enqueue_digest() {
  local chk="$1" lvl="$2" msg="$3"
  if [[ -x "$DIGEST_SCRIPT" ]]; then
    DIGEST_STATE_DIR="${DIGEST_STATE_DIR:-$STATE_DIR/digest}" \
      "$DIGEST_SCRIPT" --enqueue "hetzner-disk-check" "$chk" "$lvl" "$msg" 2>/dev/null || true
  fi
}

command -v flock >/dev/null 2>&1 || { log "ERROR: missing required binary: flock"; exit 1; }
command -v awk >/dev/null 2>&1 || { log "ERROR: missing required binary: awk"; exit 1; }

mkdir -p "$STATE_DIR" "$SAMPLE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another disk-check run is in progress (lock: $LOCK_FILE); skipping"; exit 0; }

FAILED=0
# DISK_NOW overrides the clock for deterministic fixture replay in tests.
# Production never sets it.
NOW="${DISK_NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s)";; esac

send_to() {
  # $1=to_csv $2=check-name $3=subject-suffix $4=body [$5=level_tag] [$6=crit_streak]
  local to_csv="$1" name="$2" subject="$3" body="$4" level_tag="${5:-}" crit_streak="${6:-0}"
  local state_file="${STATE_DIR}/${name}.state"
  local last_alert=0 last_status="" fail_since=0 prev_level="" prev_paged_personal=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"; prev_level="${PREV_LEVEL:-}"
    prev_paged_personal="${PAGED_PERSONAL:-0}"
  fi
  local is_recovery=0
  [[ "$subject" == RECOVERED* ]] && is_recovery=1

  # Policy (t1885u / 3bf25bda AC2 & AC3):
  # 1. WARN, predict-only, RECOVERED, and drills are DIGEST/ops-only: NEVER email alexey@.
  # 2. CRIT (PAGE) requires sustained breach (crit_streak >= DISK_BREACH_RUNS) before
  #    paging alexey@; run 1 alerts ops/digest only and escalates to alexey@ on run >= DISK_BREACH_RUNS.
  local wants_personal=0
  case ",${to_csv,,}," in
    *,alexey@*|*,*alexey.s.grigoriev@*) wants_personal=1 ;;
  esac
  local page_personal=0
  if [[ "$is_recovery" -eq 1 || "$subject" == WARN* || "$level_tag" == "WARN" || "$DISK_DRILL" == "1" ]]; then
    enqueue_digest "$name" "$subject" "$body"
    to_csv="$(strip_personal_recipients "$to_csv")"
  elif [[ "$wants_personal" -eq 1 ]]; then
    if [[ "$crit_streak" -lt "$DISK_BREACH_RUNS" ]]; then
      log "PENDING_BREACH check=${name} streak=${crit_streak}/${DISK_BREACH_RUNS}: holding personal PAGE until sustained breach"
      enqueue_digest "$name" "PENDING_CRIT" "$body"
      to_csv="$(strip_personal_recipients "$to_csv")"
    else
      page_personal=1
    fi
  fi

  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    # If previous run only notified ops (PENDING_BREACH) and this run now escalates to personal PAGE, do not dedupe!
    if [[ "$page_personal" -eq 1 && "$prev_paged_personal" -eq 0 ]]; then
      : # escalate to personal PAGE now
    else
      local elapsed_min=$(( (NOW - last_alert) / 60 ))
      if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
        printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\nPREV_LEVEL=%s\nCRIT_STREAK=%s\nPAGED_PERSONAL=%s\n' \
          "$last_alert" "$fail_since" "${level_tag:-$prev_level}" "$crit_streak" "$prev_paged_personal" > "$state_file"
        return 0  # still failing, recently alerted — dedupe
      fi
    fi
  fi
  local full_subject="[hetzner-disk-check] ${subject} (${name})"
  local sent="no"
  to_csv="${to_csv// /,}"
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
    log "WARN: no MTA (sendmail/msmtp) on this host — alert for ${name} logged only; install msmtp and configure ~/.msmtprc (see README)"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${to_csv}"
  if [[ "$is_recovery" -eq 1 ]]; then
    if [[ "$sent" != "no" ]]; then
      printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\nPREV_LEVEL=OK\nCRIT_STREAK=0\nPAGED_PERSONAL=0\n' > "$state_file"
    else
      log "WARN: RECOVERED mail for ${name} failed to send — keeping FAIL state so the next run retries"
    fi
  else
    local new_fail_since="${fail_since:-0}"
    if [[ "$last_status" != "FAIL" || -z "${fail_since:-}" || "${fail_since:-0}" -eq 0 ]]; then
      new_fail_since="$NOW"
    fi
    # A failed send must not start the dedupe window: keep the previous
    # LAST_ALERT so the next run retries immediately instead of waiting
    # ALERT_REPEAT_MIN with nobody paged.
    local new_last_alert="$NOW"
    local new_paged_personal="$prev_paged_personal"
    if [[ "$sent" == "no" ]]; then
      new_last_alert="$last_alert"
    elif [[ "$page_personal" -eq 1 ]]; then
      new_paged_personal=1
    fi
    printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\nPREV_LEVEL=%s\nCRIT_STREAK=%s\nPAGED_PERSONAL=%s\n' \
      "$new_last_alert" "$new_fail_since" "${level_tag:-$prev_level}" "$crit_streak" "$new_paged_personal" > "$state_file"
  fi
}

send_alert() { send_to "$ALERT_TO" "$@"; }
send_ops() { send_to "$ALERT_OPS_TO" "$@"; }

mark_ok() {
  # $1=check-name — sends RECOVERED (to ops/digest, never alexey@) if previous
  # state was FAIL AND the outage lasted at least RECOVER_NOTIFY_MIN_SEC.
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status="" fail_since=0 last_alert=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"; fail_since="${FAIL_SINCE:-0}"; last_alert="${LAST_ALERT:-0}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    local lasted=$(( NOW - fail_since ))
    if [[ "$fail_since" -le 0 ]]; then lasted="$RECOVER_NOTIFY_MIN_SEC"; fi
    if [[ "$lasted" -ge "$RECOVER_NOTIFY_MIN_SEC" ]]; then
      send_alert "$name" "RECOVERED" "Check '${name}' is green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ') after ${lasted}s."
    else
      printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\nPREV_LEVEL=OK\nCRIT_STREAK=0\nPAGED_PERSONAL=0\n' > "$state_file"
      log "RECOVERED-suppressed check=${name} lasted=${lasted}s (<${RECOVER_NOTIFY_MIN_SEC}s flap guard)"
    fi
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\nPREV_LEVEL=OK\nCRIT_STREAK=0\nPAGED_PERSONAL=0\n' "$last_alert" > "$state_file"
  fi
}

sanitize_mount() {
  # / -> root, /boot -> boot, /data -> data
  local m="$1"
  if [[ "$m" == "/" ]]; then echo "root"; return; fi
  echo "${m#/}" | tr '/' '-'
}

record_sample() {
  # $1=sanitized $2=avail_bytes $3=size_bytes
  local s="$1" avail="$2" size="$3"
  local f="${SAMPLE_DIR}/${s}.log"
  local last_t=0
  if [[ -f "$f" ]]; then
    last_t="$(tail -n 1 "$f" 2>/dev/null | awk '{print $1}')" || last_t=0
    [[ "$last_t" =~ ^[0-9]+$ ]] || last_t=0
  fi
  if [[ "$last_t" -eq 0 || $(( NOW - last_t )) -ge 240 ]]; then
    echo "$NOW $avail $size" >> "$f"
    tail -n 200 "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  fi
}

fill_hours() {
  # $1=sanitized $2=avail_now [$3=size_now] -> prints hours-to-full or empty.
  # Long-window LSQ must predict fill within FILL_CRIT_H, AND:
  #   - no step discontinuity: recent-window LSQ must also predict fill;
  #   - step discontinuity: tail AFTER the last outlier drop must predict
  #     fill with span >= FILL_CONFIRM_MIN_SPAN_SEC.
  # A drop is an outlier step when it exceeds max(2GiB, 0.5% size,
  # 5x median interval drop) and dominates the window total (>50%). This
  # keeps sustained growth (many similar drops) from looking like a step,
  # while a one-off bulk move (one huge drop, flat tail) never confirms.
  # Prints the long-window estimate. Empty when unknown, rising, or rejected
  # as a one-off step change followed by flat usage.
  local s="$1" avail_now="$2" size_now="${3:-0}"
  local f="${SAMPLE_DIR}/${s}.log"
  [[ -f "$f" ]] || return 0
  [[ "$size_now" =~ ^[0-9]+$ ]] || size_now=0
  local window_sec=$(( FILL_WINDOW_H * 3600 ))
  local cwindow_sec=$(( FILL_CONFIRM_WINDOW_H * 3600 ))
  awk -v now="$NOW" -v win="$window_sec" -v cwin="$cwindow_sec" \
      -v minspan="$FILL_MIN_SPAN_SEC" -v cminspan="$FILL_CONFIRM_MIN_SPAN_SEC" \
      -v avail_now="$avail_now" -v size_now="$size_now" -v crit_h="$FILL_CRIT_H" '
    $1 <= now && $2 ~ /^[0-9]+$/ && $1 >= (now - win) {
      # window samples (1-indexed); keep time order via later sort
      n++; wt[n] = $1; wa[n] = $2
      if ($1 >= (now - cwin)) {
        m++; cdt = $1 - now; ct_sum += cdt; ca_sum += $2
        ctt_sum += cdt*cdt; cta_sum += cdt*$2
        if (m == 1 || $1 < ct0) ct0 = $1
        if (m == 1 || $1 > ct1) ct1 = $1
      }
    }
    END {
      if (n < 2) exit 0
      # insertion sort window by time (n<=200)
      for (i = 2; i <= n; i++) {
        kt = wt[i]; ka = wa[i]; j = i - 1
        while (j >= 1 && wt[j] > kt) { wt[j+1] = wt[j]; wa[j+1] = wa[j]; j-- }
        wt[j+1] = kt; wa[j+1] = ka
      }
      t0 = wt[1]; t1 = wt[n]
      if ((t1 - t0) < minspan) exit 0
      st = 0; sa = 0; stt = 0; sta = 0
      for (i = 1; i <= n; i++) {
        dt = wt[i] - now
        st += dt; sa += wa[i]; stt += dt*dt; sta += dt*wa[i]
      }
      denom = n*stt - st*st
      if (denom == 0) exit 0
      rate = (n*sta - st*sa) / denom          # bytes/sec; negative = filling
      if (rate >= 0) exit 0
      hours = (avail_now / (-rate)) / 3600
      if (hours > crit_h + 0.0001) exit 0
      # ---- step discontinuity detection (outlier drop) ----
      step_floor = 2147483648                # 2 GiB floor
      if (size_now + 0 > 0) {
        rel = size_now * 0.005               # 0.5% of filesystem size
        if (rel > step_floor) step_floor = rel
      }
      nd = n - 1
      for (i = 1; i <= nd; i++) drops[i] = wa[i] - wa[i+1]
      # sort a copy for the median
      for (i = 1; i <= nd; i++) sd[i] = drops[i]
      for (i = 2; i <= nd; i++) {
        kd = sd[i]; j = i - 1
        while (j >= 1 && sd[j] > kd) { sd[j+1] = sd[j]; j-- }
        sd[j+1] = kd
      }
      if (nd % 2 == 1) med = sd[int((nd+1)/2)]
      else med = (sd[nd/2] + sd[nd/2+1]) / 2
      thr = step_floor
      if (med > 0 && 5*med > thr) thr = 5*med
      total = wa[1] - wa[n]                  # >0 means net filling
      maxdrop = drops[1]
      for (i = 2; i <= nd; i++) if (drops[i] > maxdrop) maxdrop = drops[i]
      last_large = 0
      for (i = 2; i <= n; i++) {
        if ((wa[i-1] - wa[i]) > thr) last_large = i
      }
      is_step = (last_large > 0 && total > 0 && maxdrop > thr && maxdrop > 0.5 * total)
      if (!is_step) {
        # no step: require recent-window confirmation (existing gate)
        if (m < 2) exit 0
        if ((ct1 - ct0) < cminspan) exit 0
        cdenom = m*ctt_sum - ct_sum*ct_sum
        if (cdenom == 0) exit 0
        crate = (m*cta_sum - ct_sum*ca_sum) / cdenom
        if (crate >= 0) exit 0
        chours = (avail_now / (-crate)) / 3600
        if (chours <= crit_h + 0.0001) printf "%.1f", hours
        exit 0
      }
      # step: require tail AFTER the last outlier drop to confirm growth
      tn = n - last_large + 1
      if (tn < 2) exit 0
      if ((wt[n] - wt[last_large]) < cminspan) exit 0
      tst = 0; tsa = 0; tstt = 0; tsta = 0
      for (i = last_large; i <= n; i++) {
        dt = wt[i] - now
        tst += dt; tsa += wa[i]; tstt += dt*dt; tsta += dt*wa[i]
      }
      tdenom = tn*tstt - tst*tst
      if (tdenom == 0) exit 0
      trate = (tn*tsta - tst*tsa) / tdenom
      if (trate >= 0) exit 0
      thours = (avail_now / (-trate)) / 3600
      if (thours <= crit_h + 0.0001) printf "%.1f", hours
    }' "$f"
}

check_mount() {
  # $1=mountpoint
  local mp="$1"
  local name="disk-$(sanitize_mount "$mp")"
  local line_b line_i fstype size avail target inodes ifree
  line_b="$("$DISK_DF_BIN" -PT -B1 "$mp" 2>/dev/null | awk -v m="$mp" 'NR>1 && ($7==m || $NF==m){print; exit}')"
  if [[ -z "$line_b" ]]; then
    log "FAIL check=${name}: cannot stat mount ${mp} (df failed)"
    send_alert "$name" "FAIL" "Cannot stat mount ${mp} on $(hostname): df failed."
    FAILED=1; return
  fi
  # df -PT -B1: Filesystem Type 1024-blocks Used Available Capacity Mounted-on
  # (with -B1: Filesystem Type 1B-blocks Used Available Use% Mounted-on)
  fstype="$(echo "$line_b" | awk '{print $2}')"
  size="$(echo "$line_b" | awk '{print $3}')"
  avail="$(echo "$line_b" | awk '{print $5}')"
  target="$(echo "$line_b" | awk '{print $NF}')"
  case "$fstype" in
    tmpfs|overlay|squashfs|devtmpfs)
      log "SKIP check=${name}: mount ${mp} fstype ${fstype} excluded"
      return 0;;
  esac
  if [[ ! "$size" =~ ^[0-9]+$ || ! "$avail" =~ ^[0-9]+$ || "$size" -le 0 ]]; then
    log "FAIL check=${name}: unparseable df for ${mp}: ${line_b}"
    send_alert "$name" "FAIL" "Unparseable df output for ${mp} on $(hostname): ${line_b}"
    FAILED=1; return
  fi
  line_i="$("$DISK_DF_BIN" -iP "$mp" 2>/dev/null | awk -v m="$mp" 'NR>1 && ($NF==m){print; exit}')"
  local inode_free_pct="" inode_txt="n/a"
  if [[ -n "$line_i" ]]; then
    inodes="$(echo "$line_i" | awk '{print $2}')"
    ifree="$(echo "$line_i" | awk '{print $4}')"
    if [[ "$inodes" =~ ^[0-9]+$ && "$ifree" =~ ^[0-9]+$ && "$inodes" -gt 0 ]]; then
      inode_free_pct="$(awk -v f="$ifree" -v t="$inodes" 'BEGIN{printf "%.1f", (f*100)/t}')"
      inode_txt="${inode_free_pct}% free (${ifree}/${inodes})"
    fi
  fi
  local free_pct
  free_pct="$(awk -v a="$avail" -v s="$size" 'BEGIN{printf "%.1f", (a*100)/s}')"
  record_sample "$(sanitize_mount "$mp")" "$avail" "$size"

  local state_file="${STATE_DIR}/${name}.state"
  local prev_level="OK" prev_streak=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    prev_level="${PREV_LEVEL:-OK}"
    prev_streak="${CRIT_STREAK:-0}"
  fi

  local level="OK" reason=""
  local inode_free_int="${inode_free_pct%.*}"
  [[ -z "$inode_free_int" ]] && inode_free_int=100

  # Hysteresis thresholds (t1885u AC3): once in CRIT (<8%), stay in CRIT until
  # >= DISK_CRIT_RECOVER_PCT (10%); once in WARN (<15%), stay in WARN until
  # >= DISK_WARN_RECOVER_PCT (17%). Eliminates 14.9% <-> 15.1% boundary flapping.
  local eff_crit_pct="$DISK_CRIT_FREE_PCT"
  local eff_warn_pct="$DISK_WARN_FREE_PCT"
  local eff_inode_crit_pct="$INODE_CRIT_FREE_PCT"
  local eff_inode_warn_pct="$INODE_WARN_FREE_PCT"
  if [[ "$prev_level" == "CRIT" ]]; then
    eff_crit_pct="$DISK_CRIT_RECOVER_PCT"
    eff_warn_pct="$DISK_WARN_RECOVER_PCT"
    eff_inode_crit_pct="$INODE_CRIT_RECOVER_PCT"
    eff_inode_warn_pct="$INODE_WARN_RECOVER_PCT"
  elif [[ "$prev_level" == "WARN" ]]; then
    eff_warn_pct="$DISK_WARN_RECOVER_PCT"
    eff_inode_warn_pct="$INODE_WARN_RECOVER_PCT"
  fi

  if awk -v f="$free_pct" -v c="$eff_crit_pct" 'BEGIN{exit !(f+0 < c+0)}'; then
    level="CRIT"; reason="free ${free_pct}% < crit ${eff_crit_pct}%"
  elif awk -v f="$free_pct" -v w="$eff_warn_pct" 'BEGIN{exit !(f+0 < w+0)}'; then
    level="WARN"; reason="free ${free_pct}% < warn ${eff_warn_pct}%"
  fi
  if awk -v f="$inode_free_int" -v c="$eff_inode_crit_pct" 'BEGIN{exit !(f+0 < c+0)}'; then
    level="CRIT"; reason="${reason:+$reason; }inode free ${inode_free_pct}% < crit ${eff_inode_crit_pct}%"
  elif awk -v f="$inode_free_int" -v w="$eff_inode_warn_pct" 'BEGIN{exit !(f+0 < w+0)}'; then
    if [[ "$level" != "CRIT" ]]; then level="WARN"; fi
    reason="${reason:+$reason; }inode free ${inode_free_pct}% < warn ${eff_inode_warn_pct}%"
  fi
  local fill_h
  fill_h="$(fill_hours "$(sanitize_mount "$mp")" "$avail" "$size" || true)"
  if [[ -n "$fill_h" ]]; then
    level="CRIT"; reason="${reason:+$reason; }fills within ${fill_h}h at ${FILL_WINDOW_H}h trend step-robust (threshold ${FILL_CRIT_H}h)"
  fi

  local avail_gb size_gb
  avail_gb="$(awk -v a="$avail" 'BEGIN{printf "%.1fG", a/1073741824}')"
  size_gb="$(awk -v s="$size" 'BEGIN{printf "%.0fG", s/1073741824}')"

  if [[ "$level" == "OK" ]]; then
    log "OK check=${name}: mount=${mp} free=${free_pct}% (${avail_gb} of ${size_gb}) inode=${inode_txt}"
    mark_ok "$name"
  else
    local subj="FAIL" crit_streak=0
    if [[ "$level" == "WARN" ]]; then
      subj="WARN"
      crit_streak=0
    else
      crit_streak=$(( prev_streak + 1 ))
    fi
    log "${subj} check=${name}: mount=${mp} free=${free_pct}% (${avail_gb} of ${size_gb}) inode=${inode_txt} ${reason}"
    send_alert "$name" "$subj" "Disk ${level} on $(hostname) mount ${mp}: free ${free_pct}% (${avail_gb} of ${size_gb}), inode ${inode_txt}. ${reason}. Trend window ${FILL_WINDOW_H}h, fill threshold ${FILL_CRIT_H}h." "$level" "$crit_streak"
    FAILED=1
  fi
}

report_storagebox() {
  # sshfs storagebox mount: report only, never page.
  local found=0
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    local fs mp type
    fs="$(echo "$l" | awk '{print $1}')"
    type="$(echo "$l" | awk '{print $2}')"
    mp="$(echo "$l" | awk '{print $NF}')"
    if [[ "$type" == fuse.sshfs* || "$fs" == *storagebox* || "$mp" == *storagebox* ]]; then
      local detail
      detail="$("$DISK_DF_BIN" -B1 "$mp" 2>/dev/null | awk 'NR==2{print "avail="$4" size="$2" use="$5}')"
      log "INFO storagebox mount=${mp} fstype=${type} ${detail} (report-only, never paged)"
      found=1
    fi
  done < <("$DISK_DF_BIN" -PT 2>/dev/null | awk 'NR>1')
  if [[ "$found" -eq 0 ]]; then
    log "INFO storagebox: no sshfs mount present (report-only)"
  fi
}

check_drill() {
  # Synthetic drill check: DISK_DRILL=1 pages dev@ only; normal run recovers.
  local name="disk-drill"
  local state_file="${STATE_DIR}/${name}.state"
  if [[ "$DISK_DRILL" == "1" ]]; then
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    log "DRILL check=${name}: forcing FAIL to ${ALERT_OPS_TO} at ${ts}"
    local last="0"
    [[ -f "$state_file" ]] && source "$state_file" || true
    last="${LAST_ALERT:-0}"
    if [[ "${STATUS:-}" == "FAIL" ]] && [[ $(( (NOW - last) / 60 )) -lt "$ALERT_REPEAT_MIN" ]]; then
      log "DRILL check=${name}: already alerted, deduped"
      FAILED=1; return
    fi
    send_ops "$name" "FAIL" "DRILL ${ts} from $(hostname): forced disk-alert drill (DISK_DRILL=1). Proves the Hetzner mail path to ${ALERT_OPS_TO}. Re-run without DISK_DRILL=1 to clear with RECOVERED."
    FAILED=1
  else
    if [[ -f "$state_file" ]]; then
      # shellcheck disable=SC1090
      source "$state_file" || true
      if [[ "${STATUS:-}" == "FAIL" ]]; then
        local ts
        ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        log "DRILL check=${name}: clearing drill state at ${ts}"
        local to_csv="${ALERT_OPS_TO// /,}"
        local to_header="${to_csv//,/, }"
        local -a to_args=()
        IFS=',' read -r -a to_args <<< "$to_csv"
        local sent="no"
        if command -v msmtp >/dev/null 2>&1; then
          {
            echo "From: ${ALERT_FROM_NAME} <${ALERT_FROM}>"
            echo "To: ${to_header}"
            echo "Subject: [hetzner-disk-check] RECOVERED (${name})"
            echo ""
            echo "DRILL ${ts} from $(hostname): drill cleared, mail path proved."
          } | msmtp -a "$ALERT_MSMTP_ACCOUNT" -f "$ALERT_FROM" -- "${to_args[@]}" 2>/dev/null && sent="msmtp" || log "WARN: msmtp failed for ${name}"
        elif command -v sendmail >/dev/null 2>&1; then
          {
            echo "From: ${ALERT_FROM_NAME} <${ALERT_FROM}>"
            echo "To: ${to_header}"
            echo "Subject: [hetzner-disk-check] RECOVERED (${name})"
            echo ""
            echo "DRILL ${ts} from $(hostname): drill cleared, mail path proved."
          } | sendmail -t 2>/dev/null && sent="sendmail" || log "WARN: sendmail failed for ${name}"
        else
          log "WARN: no MTA on this host — drill RECOVERED for ${name} logged only"
        fi
        log "ALERT check=${name} subject='[hetzner-disk-check] RECOVERED (${name})' via=${sent} to=${to_csv}"
        if [[ "$sent" != "no" ]]; then
          printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\n' > "$state_file"
        else
          log "WARN: drill RECOVERED mail for ${name} failed to send — keeping FAIL state so the next run retries"
        fi
      fi
    fi
    log "OK check=${name}: no drill active"
  fi
}

# ---- run ----
# shellcheck disable=SC2086
for m in $DISK_MOUNTS; do
  check_mount "$m"
done
report_storagebox
check_drill

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
