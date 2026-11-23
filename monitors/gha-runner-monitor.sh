#!/usr/bin/env bash
# Scheduled health monitor + auto-recovery for self-hosted GitHub Actions
# runners on contabo-ci and Hetzner (RMTHZ).
#
# Runs on HETZNER (RMTHZ) as a user cron job every 5 minutes (see
# install-gha-runner-monitor.sh). Never runs on contabo-ci so a dead
# contabo-ci host still gets paged from Hetzner.
#
# What it checks:
#   1. SSH reachability to contabo-ci (RUNNER_CONTABO_HOST).
#   2. Systemd status of every actions.runner.*.service on contabo-ci and
#      Hetzner. Any inactive/failed runner triggers a loud FAIL alert and
#      (when AUTO_RECOVER=1, default) automatic `systemctl start <unit>`.
#   3. Root disk usage on contabo-ci and Hetzner: FAIL when used > 85%
#      (DISK_MAX_USED_PCT, default 85).
#   4. GitHub API repo-level runner status via `gh api`: every discovered
#      runner must be online; any offline runner or API error fails loudly.
#   5. GitHub Actions queue wait: any queued workflow run waiting longer than
#      QUEUE_MAX_WAIT_SEC (default 900 = 15 min) fails loudly.
#
# Alerting:
#   - Routes via relay-alert-lib.sh (`alerts@dtcdev.click` -> `dev@dtcdev.click`),
#     with msmtp fallback. Never sends to alexey@* or orin@*.
#   - Deduped per check key (ALERT_REPEAT_MIN, default 60 min).
#   - Sends a single RECOVERED email when a failing check returns to OK.
#   - Fails loudly on transport or probe errors (never silent; retains state
#     for retry on delivery failure and exits 1).
set -euo pipefail

ENV_FILE="${GHA_RUNNER_MONITOR_ENV_FILE:-$HOME/.gha-runner-monitor.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${RELAY_ALERT_LIB:-${SCRIPT_DIR}/relay-alert-lib.sh}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- config (overridable via env) ----
STATE_DIR="${STATE_DIR:-$HOME/.local/state/gha-runner-monitor}"
LOCK_FILE="${LOCK_FILE:-$HOME/.local/state/gha-runner-monitor.lock}"

RUNNER_CONTABO_HOST="${RUNNER_CONTABO_HOST:-alexey@62.171.137.73}"
RUNNER_HOSTS="${RUNNER_HOSTS:-hetzner contabo-ci}"
RUNNER_BASE_DIR="${RUNNER_BASE_DIR:-/home/gha-runner/runners}"
SSH_TIMEOUT="${SSH_TIMEOUT:-15}"

DISK_MAX_USED_PCT="${DISK_MAX_USED_PCT:-85}"
QUEUE_MAX_WAIT_SEC="${QUEUE_MAX_WAIT_SEC:-900}"
# Ignore ancient zombie runs older than QUEUE_MAX_AGE_SEC (default 24h) that
# GitHub left in status=queued with no jobs (e.g. historical uncancelled runs).
QUEUE_MAX_AGE_SEC="${QUEUE_MAX_AGE_SEC:-86400}"
AUTO_RECOVER="${AUTO_RECOVER:-1}"

ALERT_TO="${ALERT_TO:-dev@dtcdev.click}"
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"

GH_BIN="${GH_BIN:-$(command -v gh 2>/dev/null || echo /home/alexey/.local/bin/gh)}"
SSH_BIN="${SSH_BIN:-ssh}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
DF_BIN="${DF_BIN:-df}"
RUNNER_DRILL="${RUNNER_DRILL:-0}"
RUNNER_INVENTORY_FILE="${RUNNER_INVENTORY_FILE:-}"
NOW="${MONITOR_NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s)" ;; esac

# Enforce dev@dtcdev.click-only routing (alert-triage rule: never page alexey@ or orin@).
dev_only_recipients() {
  local raw="${1// /,}" tok
  local -a kept=()
  IFS=',' read -r -a parts <<< "$raw"
  for tok in "${parts[@]}"; do
    [[ -n "$tok" ]] || continue
    case "${tok,,}" in
      alexey@*|*alexey.s.grigoriev@*|orin@*) continue ;;
      *) kept+=("$tok") ;;
    esac
  done
  if [[ "${#kept[@]}" -eq 0 ]]; then
    echo "dev@dtcdev.click"
  else
    local IFS=','
    echo "${kept[*]}"
  fi
}

for _var in ALERT_TO ALERT_OPS_TO; do
  if [[ "${!_var:-}" =~ ([Aa][Ll][Ee][Xx][Ee][Yy]@|[Aa][Ll][Ee][Xx][Ee][Yy]\.[Ss]\.[Gg][Rr][Ii][Gg][Oo][Rr][Ii][Ee][Vv]@|[Oo][Rr][Ii][Nn]@) ]]; then
    printf -v "$_var" '%s' "$(dev_only_recipients "${!_var}")"
  fi
done
unset _var

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another gha-runner-monitor run is in progress (lock: $LOCK_FILE); skipping"; exit 0; }

FAILED=0

deliver_mail() {
  # $1=to_csv $2=subject $3=body -> echoes transport ("relay"|"msmtp"|"no")
  local to_csv="$1" subject="$2" body="$3"
  if relay_send_alert "$to_csv" "$subject" "$body"; then
    echo "relay"
    return 0
  fi
  if command -v msmtp >/dev/null 2>&1; then
    local to_header="${to_csv//,/, }"
    local -a to_args=()
    IFS=',' read -r -a to_args <<< "$to_csv"
    local msmtp_args=()
    [[ -n "${ALERT_MSMTP_ACCOUNT:-}" ]] && msmtp_args+=("-a" "$ALERT_MSMTP_ACCOUNT")
    [[ -n "${ALERT_FROM:-}" ]] && msmtp_args+=("-f" "$ALERT_FROM")
    if {
      echo "From: ${ALERT_FROM_NAME} <${ALERT_FROM}>"
      echo "To: ${to_header}"
      echo "Subject: ${subject}"
      echo ""
      printf '%s\n' "$body"
    } | msmtp "${msmtp_args[@]}" -- "${to_args[@]}" 2>/dev/null; then
      echo "msmtp"
      return 0
    fi
  fi
  echo "no"
  return 1
}

send_alert() {
  # $1=check-key $2=level (FAIL|RECOVERED) $3=body [$4=to_override]
  local name="$1" level="$2" body="$3" to_override="${4:-}"
  local state_file="${STATE_DIR}/${name}.state"
  local last_alert=0 last_status="" fail_since=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"
    last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"
  fi

  local is_recovery=0
  [[ "$level" == RECOVERED* ]] && is_recovery=1

  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    local elapsed_min=$(( (NOW - last_alert) / 60 ))
    if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
      log "DEDUP check=${name}: still failing (last alert ${elapsed_min}m ago < ${ALERT_REPEAT_MIN}m)"
      return 0
    fi
  fi

  local to_csv="${to_override:-$ALERT_TO}"
  to_csv="$(dev_only_recipients "$to_csv")"
  local full_subject="[gha-runner-monitor] ${level} (${name})"
  local sent="no"
  sent="$(deliver_mail "$to_csv" "$full_subject" "$body")" || sent="no"
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${to_csv}"

  if [[ "$sent" == "no" ]]; then
    log "FAIL check=mail-${name}: alert delivery failed via relay and msmtp; retaining state for retry"
    FAILED=1
    return 1
  fi

  if [[ "$is_recovery" -eq 1 ]]; then
    printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\n' > "$state_file"
  else
    local new_fail_since="$fail_since"
    if [[ "$last_status" != "FAIL" || "${fail_since:-0}" -le 0 ]]; then
      new_fail_since="$NOW"
    fi
    printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\n' "$NOW" "$new_fail_since" > "$state_file"
  fi
}

mark_ok() {
  local name="$1" detail="${2:-}"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status="" fail_since=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    local lasted=0
    if [[ "${fail_since:-0}" -gt 0 && "$NOW" -ge "$fail_since" ]]; then
      lasted=$(( NOW - fail_since ))
    fi
    local body="Check '${name}' recovered at $(date -u -d "@${NOW}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ') after ${lasted}s."
    [[ -n "$detail" ]] && body="${body}
${detail}"
    send_alert "$name" "RECOVERED" "$body" "$ALERT_OPS_TO" || true
  else
    printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\n' > "$state_file"
  fi
}

run_on_host() {
  # $1=host ("hetzner" | "contabo-ci") $2=cmd
  local host="$1" cmd="$2"
  if [[ "$host" == "hetzner" ]]; then
    bash -c "$cmd" </dev/null
  else
    timeout "$SSH_TIMEOUT" "$SSH_BIN" -n -o BatchMode=yes -o ConnectTimeout=10 "$RUNNER_CONTABO_HOST" "$cmd"
  fi
}

check_host_systemd_and_disk() {
  local host="$1"
  local reach_key="runner-host-${host}"
  local sysd_key="runner-systemd-${host}"
  local disk_key="runner-disk-${host}"

  local probe_cmd
  probe_cmd="set -e
printf 'DISK_PCT=%s\n' \"\$(${DF_BIN} -P / | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}')\"
${SYSTEMCTL_BIN} list-unit-files --no-legend 'actions.runner.*.service' | awk '{print \$1}' | while read -r u; do
  [ -n \"\$u\" ] || continue
  st=\"\$(${SYSTEMCTL_BIN} show -p ActiveState,SubState,UnitFileState \"\$u\" | tr '\n' ' ')\"
  printf 'UNIT %s %s\n' \"\$u\" \"\$st\"
done"

  local out rc=0
  out="$(run_on_host "$host" "$probe_cmd" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "FAIL check=${reach_key}: host ${host} unreachable/probe failed (rc=${rc}): ${out:0:200}"
    send_alert "$reach_key" "FAIL" "Runner host '${host}' probe failed (rc=${rc}):
${out}" || true
    FAILED=1
    return 1
  fi
  mark_ok "$reach_key" "Host '${host}' is reachable again."

  # ---- disk check ----
  local disk_pct
  disk_pct="$(printf '%s\n' "$out" | awk -F= '/^DISK_PCT=/ {print $2; exit}')"
  if [[ ! "$disk_pct" =~ ^[0-9]+$ ]]; then
    log "FAIL check=${disk_key}: unparseable disk usage on ${host}: '${disk_pct}'"
    send_alert "$disk_key" "FAIL" "Could not parse root disk usage on ${host}." || true
    FAILED=1
  elif [[ "$disk_pct" -gt "$DISK_MAX_USED_PCT" ]]; then
    log "FAIL check=${disk_key}: ${host} root disk ${disk_pct}% > ${DISK_MAX_USED_PCT}%"
    send_alert "$disk_key" "FAIL" "Runner host '${host}' root disk usage is ${disk_pct}% (threshold > ${DISK_MAX_USED_PCT}%). Check /home/gha-runner/runners/*/_work and run /usr/local/sbin/gha-runner-cleanup.sh." || true
    FAILED=1
  else
    log "OK check=${disk_key}: ${host} root disk ${disk_pct}% <= ${DISK_MAX_USED_PCT}%"
    mark_ok "$disk_key" "Root disk on ${host} is ${disk_pct}% (<= ${DISK_MAX_USED_PCT}%)."
  fi

  # ---- systemd runner units check + auto-recovery ----
  local total_units=0 bad_units=() recover_notes=()
  while IFS= read -r line; do
    [[ "$line" == UNIT\ * ]] || continue
    total_units=$((total_units + 1))
    local unit active sub ustate
    unit="$(awk '{print $2}' <<< "$line")"
    active="$(sed -n 's/.*ActiveState=\([^ ]*\).*/\1/p' <<< "$line")"
    sub="$(sed -n 's/.*SubState=\([^ ]*\).*/\1/p' <<< "$line")"
    ustate="$(sed -n 's/.*UnitFileState=\([^ ]*\).*/\1/p' <<< "$line")"
    if [[ "$active" != "active" || "$sub" != "running" ]]; then
      bad_units+=("${unit} (active=${active:-unknown}, sub=${sub:-unknown}, enabled=${ustate:-unknown})")
      if [[ "$AUTO_RECOVER" == "1" ]]; then
        local r_rc=0
        run_on_host "$host" "sudo -n ${SYSTEMCTL_BIN} start '${unit}'" >/dev/null 2>&1 || r_rc=$?
        if [[ "$r_rc" -eq 0 ]]; then
          log "AUTO_RECOVER host=${host} unit=${unit}: systemctl start succeeded"
          recover_notes+=("auto-recovery: systemctl start ${unit} succeeded")
        else
          log "AUTO_RECOVER_FAIL host=${host} unit=${unit}: systemctl start failed (rc=${r_rc})"
          recover_notes+=("auto-recovery: systemctl start ${unit} FAILED (rc=${r_rc})")
        fi
      fi
    fi
  done <<< "$out"

  if [[ "$total_units" -eq 0 ]]; then
    log "FAIL check=${sysd_key}: 0 actions.runner.*.service units found on ${host}"
    send_alert "$sysd_key" "FAIL" "No actions.runner.*.service units found on ${host}." || true
    FAILED=1
  elif [[ "${#bad_units[@]}" -gt 0 ]]; then
    local detail
    detail="$(printf '  - %s\n' "${bad_units[@]}")"
    if [[ "${#recover_notes[@]}" -gt 0 ]]; then
      detail="${detail}
Auto-recovery actions:
$(printf '  - %s\n' "${recover_notes[@]}")"
    fi
    log "FAIL check=${sysd_key}: ${#bad_units[@]}/${total_units} runner units unhealthy on ${host}"
    send_alert "$sysd_key" "FAIL" "Unhealthy runner systemd services on ${host} (${#bad_units[@]}/${total_units}):
${detail}" || true
    FAILED=1
  else
    log "OK check=${sysd_key}: all ${total_units} runner services active/running on ${host}"
    mark_ok "$sysd_key" "All ${total_units} runner services on ${host} are active/running."
  fi
}

discover_inventory() {
  # Prints TSV lines: <host>\t<agentName>\t<owner/repo>
  if [[ -n "$RUNNER_INVENTORY_FILE" ]]; then
    cat "$RUNNER_INVENTORY_FILE"
    return 0
  fi
  local host inv_cmd
  inv_cmd="sudo -n bash -c 'shopt -s nullglob; for f in ${RUNNER_BASE_DIR}/*/.runner; do jq -r \"[.agentName, .gitHubUrl] | @tsv\" \"\$f\"; done'"
  for host in $RUNNER_HOSTS; do
    local out rc=0
    out="$(run_on_host "$host" "$inv_cmd" 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "WARN: failed to read runner inventory on ${host} (rc=${rc})"
      continue
    fi
    while IFS=$'\t' read -r agent url; do
      [[ -n "$agent" && -n "$url" ]] || continue
      local repo="${url#https://github.com/}"
      repo="${repo%/}"
      printf '%s\t%s\t%s\n' "$host" "$agent" "$repo"
    done <<< "$out"
  done
}

check_github_runners_and_queues() {
  local api_key="runner-gh-api"
  local status_key="runner-github-status"
  local queue_key="runner-queue-wait"

  if [[ ! -x "$GH_BIN" ]] && ! command -v "$GH_BIN" >/dev/null 2>&1; then
    log "FAIL check=${api_key}: gh CLI not found (${GH_BIN})"
    send_alert "$api_key" "FAIL" "GitHub CLI '${GH_BIN}' not found; cannot check runner status or workflow queues." || true
    FAILED=1
    return 1
  fi

  local inv_file
  inv_file="$(mktemp)"
  trap 'rm -f "${inv_file:-}"' RETURN
  discover_inventory > "$inv_file"

  if [[ ! -s "$inv_file" ]]; then
    log "FAIL check=${api_key}: runner inventory is empty"
    send_alert "$api_key" "FAIL" "Could not discover any self-hosted runners from ${RUNNER_BASE_DIR}/*/.runner on hosts: ${RUNNER_HOSTS}." || true
    FAILED=1
    return 1
  fi

  local result
  result="$(python3 - "$inv_file" "$GH_BIN" "$NOW" "$QUEUE_MAX_WAIT_SEC" "$QUEUE_MAX_AGE_SEC" <<'PY'
import datetime
import json
import subprocess
import sys

inv_path, gh_bin = sys.argv[1], sys.argv[2]
now_s, max_wait_s, max_age_s = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

expected_by_repo = {}
with open(inv_path, "r", encoding="utf-8") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        host, agent, repo = parts
        expected_by_repo.setdefault(repo, []).append((host, agent))

api_errors = []
offline_runners = []
stuck_runs = []
total_expected = 0
total_online = 0

for repo in sorted(expected_by_repo):
    # 1. Repo-level runners
    p = subprocess.run(
        [gh_bin, "api", f"repos/{repo}/actions/runners?per_page=100"],
        capture_output=True, text=True, timeout=30
    )
    if p.returncode != 0:
        api_errors.append(f"{repo} runners API rc={p.returncode}: {(p.stderr or p.stdout).strip()[:200]}")
    else:
        try:
            data = json.loads(p.stdout)
        except Exception as exc:
            api_errors.append(f"{repo} runners JSON parse error: {exc}")
            data = None
        if data is not None:
            gh_runners = {r.get("name"): r.get("status", "unknown") for r in data.get("runners", [])}
            for host, agent in expected_by_repo[repo]:
                total_expected += 1
                st = gh_runners.get(agent)
                if st == "online":
                    total_online += 1
                elif st is None:
                    offline_runners.append(f"{repo}: {agent} ({host}) missing from GitHub API")
                else:
                    offline_runners.append(f"{repo}: {agent} ({host}) status={st}")
            # Also catch any extra contabo-*/hetzner-* runners registered in GitHub that went offline
            expected_names = {a for _, a in expected_by_repo[repo]}
            for rname, st in sorted(gh_runners.items()):
                if rname not in expected_names and (rname.startswith("contabo-") or rname.startswith("hetzner-")):
                    if st != "online":
                        offline_runners.append(f"{repo}: {rname} (extra) status={st}")

    # 2. Queued workflow runs
    q = subprocess.run(
        [gh_bin, "api", f"repos/{repo}/actions/runs?status=queued&per_page=30"],
        capture_output=True, text=True, timeout=30
    )
    if q.returncode != 0:
        api_errors.append(f"{repo} queued runs API rc={q.returncode}: {(q.stderr or q.stdout).strip()[:200]}")
    else:
        try:
            qdata = json.loads(q.stdout)
        except Exception as exc:
            api_errors.append(f"{repo} queued runs JSON parse error: {exc}")
            qdata = None
        if qdata is not None:
            for run in qdata.get("workflow_runs", []):
                created_raw = run.get("created_at") or ""
                if not created_raw:
                    continue
                created_dt = datetime.datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
                age_sec = int(now_s - created_dt.timestamp())
                if age_sec > max_wait_s and (max_age_s <= 0 or age_sec <= max_age_s):
                    age_min = round(age_sec / 60.0, 1)
                    stuck_runs.append(
                        f"{repo}: run #{run.get('id')} '{run.get('name')}' queued for {age_min}m (> {max_wait_s // 60}m) {run.get('html_url', '')}"
                    )

print(json.dumps({
    "repos_checked": len(expected_by_repo),
    "total_expected": total_expected,
    "total_online": total_online,
    "api_errors": api_errors,
    "offline_runners": offline_runners,
    "stuck_runs": stuck_runs,
}))
PY
)" || {
    log "FAIL check=${api_key}: python GitHub API checker crashed"
    send_alert "$api_key" "FAIL" "GitHub API runner/queue checker crashed unexpectedly." || true
    FAILED=1
    return 1
  }

  local repos_checked total_expected total_online api_err_count offline_count stuck_count
  repos_checked="$(jq -r '.repos_checked' <<< "$result")"
  total_expected="$(jq -r '.total_expected' <<< "$result")"
  total_online="$(jq -r '.total_online' <<< "$result")"
  api_err_count="$(jq -r '.api_errors | length' <<< "$result")"
  offline_count="$(jq -r '.offline_runners | length' <<< "$result")"
  stuck_count="$(jq -r '.stuck_runs | length' <<< "$result")"

  if [[ "$api_err_count" -gt 0 ]]; then
    local err_lines
    err_lines="$(jq -r '.api_errors[] | "  - " + .' <<< "$result")"
    log "FAIL check=${api_key}: ${api_err_count} GitHub API errors across ${repos_checked} repos"
    send_alert "$api_key" "FAIL" "GitHub API check errors (${api_err_count}):
${err_lines}" || true
    FAILED=1
  else
    log "OK check=${api_key}: GitHub API reachable across ${repos_checked} repos"
    mark_ok "$api_key" "GitHub API succeeded across ${repos_checked} repos."
  fi

  if [[ "$offline_count" -gt 0 ]]; then
    local off_lines
    off_lines="$(jq -r '.offline_runners[] | "  - " + .' <<< "$result")"
    log "FAIL check=${status_key}: ${offline_count} runners offline/missing (${total_online}/${total_expected} online)"
    send_alert "$status_key" "FAIL" "Self-hosted GitHub runners offline/missing (${total_online}/${total_expected} online):
${off_lines}" || true
    FAILED=1
  else
    log "OK check=${status_key}: all ${total_online}/${total_expected} self-hosted runners online in GitHub API"
    mark_ok "$status_key" "All ${total_online}/${total_expected} self-hosted runners are online in GitHub API."
  fi

  if [[ "$stuck_count" -gt 0 ]]; then
    local stuck_lines
    stuck_lines="$(jq -r '.stuck_runs[] | "  - " + .' <<< "$result")"
    log "FAIL check=${queue_key}: ${stuck_count} workflow runs queued > $(( QUEUE_MAX_WAIT_SEC / 60 ))m"
    send_alert "$queue_key" "FAIL" "GitHub Actions workflow runs queued longer than $(( QUEUE_MAX_WAIT_SEC / 60 )) min (${stuck_count}):
${stuck_lines}" || true
    FAILED=1
  else
    log "OK check=${queue_key}: no workflow runs queued > $(( QUEUE_MAX_WAIT_SEC / 60 ))m across ${repos_checked} repos"
    mark_ok "$queue_key" "No workflow runs queued > $(( QUEUE_MAX_WAIT_SEC / 60 ))m across ${repos_checked} repos."
  fi
}

# ---- main ----
if [[ "$RUNNER_DRILL" == "1" ]]; then
  log "DRILL check=runner-drill: RUNNER_DRILL=1 (ops-only alert path test)"
  send_alert "runner-drill" "FAIL" "DRILL: forced gha-runner-monitor alert to prove alert delivery to ${ALERT_OPS_TO}. Re-run without RUNNER_DRILL=1 to clear." "$ALERT_OPS_TO" || true
  FAILED=1
else
  mark_ok "runner-drill" "Runner monitor drill cleared."
fi

for host in $RUNNER_HOSTS; do
  check_host_systemd_and_disk "$host" || true
done

check_github_runners_and_queues || true

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
