#!/usr/bin/env bash
# Disk & resilience guard for self-hosted GitHub Actions runner hosts
# (contabo-ci and Hetzner RMTHZ).
#
# What it does:
#   1. Ensures every actions.runner.*.service unit on this host has the
#      20-resilience.conf systemd drop-in (Restart=always, RestartSec=10,
#      StartLimitIntervalSec=0, MemoryHigh/MemoryMax, OOMScoreAdjust=200)
#      and is enabled to survive reboot.
#   2. Cleans stale _work/_temp/* and _work/* directories for IDLE runners
#      (never touching a runner with an active Runner.Worker process) and
#      rotates old _diag/*.log files.
#   3. When Docker is present and root disk usage exceeds DOCKER_PRUNE_PCT
#      (default 70%), prunes unused Docker objects older than 24h.
#
# Usage:
#   gha-runner-cleanup.sh [--dry-run]
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

RUNNER_BASE_DIR="${RUNNER_BASE_DIR:-/home/gha-runner/runners}"
CLEANUP_WORK_DAYS="${CLEANUP_WORK_DAYS:-7}"
CLEANUP_TEMP_DAYS="${CLEANUP_TEMP_DAYS:-1}"
CLEANUP_DIAG_DAYS="${CLEANUP_DIAG_DAYS:-7}"
AGGRESSIVE_DISK_PCT="${AGGRESSIVE_DISK_PCT:-75}"
DOCKER_PRUNE_PCT="${DOCKER_PRUNE_PCT:-70}"
SKIP_SYSTEMD_HARDEN="${SKIP_SYSTEMD_HARDEN:-0}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

log() { printf '%s [gha-runner-cleanup] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

root_disk_used_pct() {
  if [[ -n "${DISK_USED_PCT_OVERRIDE:-}" ]]; then
    echo "$DISK_USED_PCT_OVERRIDE"
    return
  fi
  df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

detect_memory_limits() {
  if [[ -n "${RUNNER_MEMORY_HIGH:-}" && -n "${RUNNER_MEMORY_MAX:-}" ]]; then
    echo "${RUNNER_MEMORY_HIGH} ${RUNNER_MEMORY_MAX}"
    return
  fi
  local mem_kb=0
  if [[ -r /proc/meminfo ]]; then
    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  fi
  # <= 8 GiB RAM (e.g., contabo-ci 3.8 GiB + 4 GiB swap): cap per-runner at 2.5G/3.25G
  # > 8 GiB RAM (e.g., Hetzner 62 GiB): cap per-runner at 8G/12G
  if [[ "${mem_kb:-0}" -le 8388608 ]]; then
    echo "2560M 3328M"
  else
    echo "8G 12G"
  fi
}

ensure_systemd_resilience() {
  [[ "$SKIP_SYSTEMD_HARDEN" == "1" ]] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  local mem_high mem_max
  read -r mem_high mem_max <<< "$(detect_memory_limits)"

  local desired
  desired="$(cat <<EOF
# Managed by gha-runner-cleanup / install-gha-runner-hardening (machine-management)
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
MemoryHigh=${mem_high}
MemoryMax=${mem_max}
OOMScoreAdjust=200
EOF
)"

  local changed=0 unit dropin_dir dropin_file
  shopt -s nullglob
  for unit_path in "${SYSTEMD_DIR}"/actions.runner.*.service; do
    unit="$(basename "$unit_path")"
    dropin_dir="${SYSTEMD_DIR}/${unit}.d"
    dropin_file="${dropin_dir}/20-resilience.conf"
    if [[ ! -f "$dropin_file" ]] || [[ "$(cat "$dropin_file")" != "$desired" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would write ${dropin_file}"
      else
        mkdir -p "$dropin_dir"
        printf '%s\n' "$desired" > "$dropin_file"
        chmod 0644 "$dropin_file"
        log "UPDATED drop-in ${dropin_file}"
      fi
      changed=1
    fi
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would enable ${unit}"
      else
        systemctl enable "$unit" >/dev/null 2>&1 || log "WARN: failed to enable ${unit}"
        log "ENABLED ${unit}"
      fi
      changed=1
    fi
  done
  shopt -u nullglob

  if [[ "$changed" -eq 1 && "$DRY_RUN" == "0" ]]; then
    systemctl daemon-reload
    log "Reloaded systemd daemon after updating runner drop-ins"
  fi
}

runner_is_busy() {
  local rdir="$1"
  if [[ -n "${BUSY_RUNNERS_OVERRIDE:-}" ]]; then
    local name
    name="$(basename "$rdir")"
    [[ ",${BUSY_RUNNERS_OVERRIDE}," == *",${name},"* ]]
    return
  fi
  pgrep -f "${rdir}/bin/Runner\.Worker" >/dev/null 2>&1
}

clean_dir_entries() {
  local target="$1" age_flag="$2" age_val="$3" label="$4"
  [[ -d "$target" ]] || return 0
  local count
  count="$(find "$target" -mindepth 1 -maxdepth 1 "$age_flag" "$age_val" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${count:-0}" -gt 0 ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: would remove ${count} entries from ${target} (${label})"
  else
    find "$target" -mindepth 1 -maxdepth 1 "$age_flag" "$age_val" -exec rm -rf -- {} + 2>/dev/null || true
    log "CLEANED ${count} entries from ${target} (${label})"
  fi
}

cleanup_runners() {
  local used_pct
  used_pct="$(root_disk_used_pct)"
  log "Starting runner cleanup (root disk used=${used_pct}%, dry_run=${DRY_RUN})"

  if [[ ! -d "$RUNNER_BASE_DIR" ]]; then
    log "WARN: runner base dir ${RUNNER_BASE_DIR} does not exist; skipping workdir cleanup"
    return 0
  fi

  local aggressive=0
  if [[ "$used_pct" =~ ^[0-9]+$ && "$used_pct" -ge "$AGGRESSIVE_DISK_PCT" ]]; then
    aggressive=1
    log "Disk usage ${used_pct}% >= ${AGGRESSIVE_DISK_PCT}%: using aggressive cleanup thresholds"
  fi

  local rdir rname
  shopt -s nullglob
  for rdir in "${RUNNER_BASE_DIR}"/*; do
    [[ -d "$rdir" ]] || continue
    rname="$(basename "$rdir")"

    # _diag logs are safe to prune even while a runner is busy
    if [[ -d "${rdir}/_diag" ]]; then
      local diag_count
      diag_count="$(find "${rdir}/_diag" -type f -name '*.log' -mtime +"${CLEANUP_DIAG_DAYS}" 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "${diag_count:-0}" -gt 0 ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY-RUN: would remove ${diag_count} old _diag logs in ${rname}"
        else
          find "${rdir}/_diag" -type f -name '*.log' -mtime +"${CLEANUP_DIAG_DAYS}" -delete 2>/dev/null || true
          log "CLEANED ${diag_count} old _diag logs in ${rname}"
        fi
      fi
    fi

    # Never touch _work while a job is actively executing in this runner
    if runner_is_busy "$rdir"; then
      log "SKIP _work cleanup for busy runner ${rname}"
      continue
    fi

    if [[ "$aggressive" -eq 1 ]]; then
      clean_dir_entries "${rdir}/_work/_temp" "-mmin" "+60" "temp>60m"
      # Prune stale repo checkouts / caches in _work (excluding _tool and _temp)
      if [[ -d "${rdir}/_work" ]]; then
        local w_entry
        for w_entry in "${rdir}/_work"/*; do
          [[ -e "$w_entry" ]] || continue
          case "$(basename "$w_entry")" in
            _tool|_temp|_actions) continue ;;
          esac
          if find "$w_entry" -maxdepth 0 -mtime +1 2>/dev/null | grep -q .; then
            if [[ "$DRY_RUN" == "1" ]]; then
              log "DRY-RUN: would remove stale workdir ${w_entry}"
            else
              rm -rf -- "$w_entry"
              log "CLEANED stale workdir ${w_entry}"
            fi
          fi
        done
      fi
    else
      clean_dir_entries "${rdir}/_work/_temp" "-mtime" "+${CLEANUP_TEMP_DAYS}" "temp>${CLEANUP_TEMP_DAYS}d"
      if [[ -d "${rdir}/_work" ]]; then
        local w_entry
        for w_entry in "${rdir}/_work"/*; do
          [[ -e "$w_entry" ]] || continue
          case "$(basename "$w_entry")" in
            _tool|_temp|_actions) continue ;;
          esac
          if find "$w_entry" -maxdepth 0 -mtime +"${CLEANUP_WORK_DAYS}" 2>/dev/null | grep -q .; then
            if [[ "$DRY_RUN" == "1" ]]; then
              log "DRY-RUN: would remove stale workdir ${w_entry}"
            else
              rm -rf -- "$w_entry"
              log "CLEANED stale workdir ${w_entry}"
            fi
          fi
        done
      fi
    fi
  done
  shopt -u nullglob

  if command -v docker >/dev/null 2>&1 && [[ "$used_pct" =~ ^[0-9]+$ && "$used_pct" -ge "$DOCKER_PRUNE_PCT" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN: would run docker system prune -af --filter until=24h (disk=${used_pct}%)"
    else
      log "Running docker system prune -af --filter until=24h (disk=${used_pct}%)"
      docker system prune -af --filter "until=24h" >/dev/null 2>&1 || log "WARN: docker system prune failed"
    fi
  fi

  local after_pct
  after_pct="$(root_disk_used_pct)"
  log "Finished runner cleanup (root disk used=${after_pct}%)"
}

ensure_systemd_resilience
cleanup_runners
