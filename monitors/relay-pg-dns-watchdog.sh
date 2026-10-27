#!/usr/bin/env bash
# relay-pg-dns-watchdog — keep Coolify app containers able to reach their Postgres.
#
# Incident class (t1205u, 2026-10-22/23): Coolify recreates a standalone
# Postgres container with a random uuid name (e.g. mqimefrti7ratmaliirnikov)
# and a NEW container IP, while long-running app containers (relay-staging
# ses-ingress / workers) keep using a stale cached IP (10.0.1.2 vs live
# 10.0.1.15) -> connection refused -> SES webhook drain silently stops -> SQS
# message age climbs past 300s -> DLQ. A manual `docker restart` of the app
# container cleared the stale state (t1205u remedy).
#
# This watchdog runs ON the data node (contabo-b) EVERY MINUTE (cron file:
# relay-pg-dns-watchdog.cron) and:
#   1. Finds the Coolify Postgres container(s) via the stable label
#      coolify.resourceName=<PG_LABELS> (default: pg-relay).
#   2. Stands down (NO restarts) if that Postgres is itself unhealthy —
#      monitors/coolify-healthcheck.sh already pages for real PG outages.
#   3. Discovers dependent app containers: running containers on the same
#      docker network(s) whose env has DATABASE_URL or POSTGRES_HOST.
#   4. From INSIDE each dependent, verifies BOTH:
#        a) Fresh DNS + TCP connect to DB host:port (probe_from_container), AND
#        b) Running-worker progress/state (probe_worker_progress, t1218u):
#           - Active :5432 TCP sockets in /proc/1/net/tcp{,6} match the live
#             Postgres container's current IPv4/IPv6 addresses (catches in-process
#             cached stale IPs even when fresh `docker exec` DNS resolves the new IP).
#           - Long-lived background workers (non-web) do not pre-date a Postgres
#             container recreation (StartedAt < PG StartedAt).
#           - `ses-ingress` latest batch did not fail 100% (`deleted=0 failed>0`).
#           - Background workers (`db_worker`, `scheduler`, callbacks, imports)
#             have no uncaught `OperationalError` / `InterfaceError` after their
#             latest startup banner (catches `StatReloader` keeping PID 1 alive
#             after the worker thread dies).
#   5. Queries Postgres directly (check_pg_worker_progress, t1218u) to verify:
#        a) `relay_scheduler_heartbeat.ticked_at` freshness (<= SCHEDULER_MAX_AGE_SEC),
#        b) `django_tasks_database_dbtaskresult` has no due `READY` tasks stuck
#           longer than TASK_QUEUE_MAX_READY_AGE_SEC (`provider-events` / `default`).
#   6. On failure of a healthy-Postgres-dependent (TCP or progress check):
#        - referenced name no longer known to docker DNS and != current PG
#          name -> STALE-NAME (PG redeployed): restart can NOT fix -> alert
#          with the fix (redeploy app / update env). No restart.
#        - else -> `docker restart <dep>` (per-container cooldown gated),
#          re-probe TCP + worker progress; alert AUTOHEALED or STILL-FAILING.
#
# Policy (t1210u/t1211u/t1218u): NO static Postgres IP pin on the `coolify`
# network (Coolify overwrites compose on recreate and unreserved bridge IPAM
# risks hard PG start failure if another container claims the pinned IP).
#
# Guard rails: never prints env VALUES (no DATABASE_URL secrets in logs —
# only variable names, host:port and resolved addresses); only restarts
# containers that are RUNNING and reference the Postgres; stands down
# entirely when Postgres itself is down.
#
# Alerting: same email pattern as coolify-healthcheck (ALERT_TO, dedupe,
# RECOVERED). No alert for real PG-down (healthcheck owns that page).
#
# Exit code: 0 all green; 1 a dependent (or PG discovery) failed; 2 PG
# self-check failed (standdown, healthcheck pages).
# NOTE: `set -e` is deliberately NOT used — every probe is expected to be
# able to fail; return codes are handled explicitly.
set -uo pipefail

ENV_FILE="${RELAY_PG_DNS_WATCHDOG_ENV_FILE:-/etc/relay-pg-dns-watchdog.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- config (overridable via env file) ----
STATE_DIR="${STATE_DIR:-/var/lib/relay-pg-dns-watchdog}"
LOCK_FILE="${LOCK_FILE:-/var/lock/relay-pg-dns-watchdog.lock}"
LOG_FILE="${LOG_FILE:-/var/log/relay-pg-dns-watchdog.log}"

# Coolify resource names to watch (space-separated). Each gets the stable
# coolify.resourceName label lookup. Add "pg-shared" to also watch cmp/aisl/
# website app containers (same stale-DNS failure mode).
PG_LABELS="${PG_LABELS:-pg-relay}"

# PG self-check (docker exec pg_isready, local socket — no password needed).
PGUSER="${PGUSER:-pgadmin}"
PG_DB="${PG_DB:-relay}"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"          # seconds, per TCP attempt
RESTART_VERIFY_WAIT="${RESTART_VERIFY_WAIT:-12}" # seconds after restart before re-probe
RESTART_COOLDOWN_SEC="${RESTART_COOLDOWN_SEC:-900}"  # per container
DEP_STARTUP_GRACE_SEC="${DEP_STARTUP_GRACE_SEC:-120}"
DNS_RECHECK_WAIT_SEC="${DNS_RECHECK_WAIT_SEC:-25}"
DRY_RUN="${DRY_RUN:-0}"
# Never-restart container-name regex (extra safety net on top of the env gate).
DEPENDENT_EXCLUDE="${DEPENDENT_EXCLUDE:-^coolify-proxy$|^coolify-realtime$|^watchtower$}"

# Worker-progress / stale-pool checks beyond fresh sibling TCP (t1218u):
PROGRESS_CHECKS="${PROGRESS_CHECKS:-1}"
PROGRESS_SQL_CHECKS="${PROGRESS_SQL_CHECKS:-1}"
RESTART_WORKERS_OLDER_THAN_PG="${RESTART_WORKERS_OLDER_THAN_PG:-1}"
PG_RECREATE_GRACE_SEC="${PG_RECREATE_GRACE_SEC:-15}"
SCHEDULER_MAX_AGE_SEC="${SCHEDULER_MAX_AGE_SEC:-180}"
TASK_QUEUE_MAX_READY_AGE_SEC="${TASK_QUEUE_MAX_READY_AGE_SEC:-180}"
# Handled per-task DB error (deadlock / serialization failure) with no later
# successful work, in a loop the SQL queue check does not cover: wait this long
# for progress before treating it as no-progress and restarting (AC-B1).
HANDLED_DB_ERROR_GRACE_SEC="${HANDLED_DB_ERROR_GRACE_SEC:-300}"

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"
# Outage / flap notification tuning (t1273u / t1342u):
# Suppress RECOVERED notice if outage lasted shorter than this many seconds (default 600s = 10m)
RECOVER_NOTIFY_MIN_SEC="${RECOVER_NOTIFY_MIN_SEC:-600}"
# At most one AUTOHEALED notice per check per cooldown window (default 3600s = 1h)
AUTOHEALED_COOLDOWN_SEC="${AUTOHEALED_COOLDOWN_SEC:-3600}"

command -v docker >/dev/null 2>&1 || { log "FATAL: docker not found"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "FATAL: missing required binary: flock"; exit 1; }

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another watchdog run in progress (lock: $LOCK_FILE); skipping"; exit 0; }

NOW="$(date +%s)"
FAILED=0
EXIT_CODE=0

safe_name() { printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_' | cut -c1-80; }

prune_stale_state_files() {
  # Prune state and stamp files for containers that no longer exist (t1342u)
  [[ -d "$STATE_DIR" ]] || return 0
  local f base cname
  for f in "$STATE_DIR"/dep-*.state; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .state)"
    cname="${base#dep-}"
    if ! docker inspect "$cname" >/dev/null 2>&1; then
      log "PRUNE check=${base}: container '${cname}' no longer exists — removed stale state"
      rm -f "$f" "${STATE_DIR}/restart-${cname}.stamp"
    fi
  done
  for f in "$STATE_DIR"/warn-dep-*.state "$STATE_DIR"/warn-dep-*.key "$STATE_DIR"/warn-dep-*.pending "$STATE_DIR"/pending-dep-*.since; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"; base="${base%.*}"
    cname="${base#warn-dep-}"; cname="${cname#pending-dep-}"
    if ! docker inspect "$cname" >/dev/null 2>&1; then
      log "PRUNE check=${base}: container '${cname}' no longer exists — removed stale state"
      rm -f "$f"
    fi
  done
  for f in "$STATE_DIR"/restart-*.stamp; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .stamp)"
    cname="${base#restart-}"
    if ! docker inspect "$cname" >/dev/null 2>&1; then
      log "PRUNE stamp=${base}: container '${cname}' no longer exists — removed stale stamp"
      rm -f "$f"
    fi
  done
}

send_alert() {
  # $1=check-name $2=subject-suffix $3=body  (same dedupe as coolify-healthcheck)
  # $4=priority: "normal" (default) or "low" (adds X-Priority: 5 / Importance:
  # low headers; used for WARN notices that need no action).
  # Returns 1 only when a WARN notice was rate-limited or not delivered
  # (caller keeps it pending and retries on a later run).
  local name="$1" subject="$2" body="$3" priority="${4:-normal}"
  local state_file="${STATE_DIR}/${name}.state"
  local last_alert=0 last_status="" fail_since=0 last_autohealed=0 autoheal_count=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"
    last_autohealed="${LAST_AUTOHEALED:-0}"
    autoheal_count="${AUTOHEAL_COUNT:-0}"
  fi

  if [[ "$subject" == AUTOHEALED* ]]; then
    autoheal_count=$(( autoheal_count + 1 ))
    if [[ "$last_autohealed" =~ ^[0-9]+$ && "$last_autohealed" -gt 0 ]]; then
      local elapsed_autoheal=$(( NOW - last_autohealed ))
      if (( elapsed_autoheal < AUTOHEALED_COOLDOWN_SEC )); then
        log "AUTOHEALED check=${name}: alert suppressed (cooldown active: ${elapsed_autoheal}s < ${AUTOHEALED_COOLDOWN_SEC}s, count=${autoheal_count})"
        printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\nLAST_AUTOHEALED=%s\nAUTOHEAL_COUNT=%s\n' \
          "$last_autohealed" "$autoheal_count" > "$state_file"
        return 0
      fi
    fi
    # First autoheal in this window, or cooldown window expired
    last_autohealed="$NOW"
    if (( autoheal_count > 1 )); then
      body="${body}"$'\n\n'"(Auto-heal events in cooldown window: ${autoheal_count})"
    fi
  elif [[ "$subject" == RECOVERED* ]]; then
    # RECOVERED notification rate-limiting handled via mark_ok / RECOVER_NOTIFY_MIN_SEC
    :
  elif [[ "$subject" == WARN* ]]; then
    # Low-priority notices: at most one per ALERT_REPEAT_MIN per check. A
    # rate-limited notice is not dropped: the caller keeps it pending and
    # it goes out on a later run.
    if [[ "$last_status" == "WARN" ]] && (( (NOW - last_alert) / 60 < ALERT_REPEAT_MIN )); then
      log "WARN check=${name}: low-priority notice rate-limited (ALERT_REPEAT_MIN=${ALERT_REPEAT_MIN}); will send on a later run"
      return 1
    fi
  else
    # FAIL alert dedupe
    if [[ "$last_status" == "FAIL" ]]; then
      local elapsed_min=$(( (NOW - last_alert) / 60 ))
      if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
        return 0  # still failing, recently alerted — dedupe
      fi
    fi
  fi

  local full_subject="[relay-pg-dns-watchdog] ${subject} (${name})"
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

  local prio_headers=""
  if [[ "$priority" == "low" ]]; then
    prio_headers=$'X-Priority: 5 (Lowest)\nImportance: low\nPriority: non-urgent\n'
  fi

  local sent="no"
  if command -v msmtp >/dev/null 2>&1; then
    if {
      echo "From: ${from_header}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      printf '%s' "$prio_headers"
      echo ""
      printf '%s\n' "$body"
    } | msmtp "${msmtp_args[@]}" -- "${to_args[@]}" 2>/dev/null; then sent="msmtp"; fi
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
      printf '%s' "$prio_headers"
      echo ""
      printf '%s\n' "$body"
    } | sendmail "${sendmail_args[@]}" 2>/dev/null; then sent="sendmail"; fi
  else
    log "WARN: no MTA (sendmail/msmtp) — alert for ${name} logged only"
  fi
  log "ALERT check=${name} subject='${full_subject}' priority=${priority} via=${sent} to=${ALERT_TO}"

  if [[ "$subject" == WARN* ]]; then
    # Not delivered: keep the notice pending so a later run retries it.
    [[ "$sent" == "no" ]] && return 1
    printf 'STATUS=WARN\nLAST_ALERT=%s\nFAIL_SINCE=0\nLAST_AUTOHEALED=0\nAUTOHEAL_COUNT=0\n' "$NOW" > "$state_file"
    return 0
  fi

  local is_recovery=0
  [[ "$subject" == RECOVERED* || "$subject" == AUTOHEALED* ]] && is_recovery=1
  if [[ "$is_recovery" -eq 1 ]]; then
    printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\nLAST_AUTOHEALED=%s\nAUTOHEAL_COUNT=%s\n' \
      "$last_autohealed" "$autoheal_count" > "$state_file"
  else
    if [[ "${last_status:-}" != "FAIL" || -z "${FAIL_SINCE:-}" || "${FAIL_SINCE:-0}" -eq 0 ]]; then
      fail_since="$NOW"
    fi
    printf 'STATUS=FAIL\nLAST_ALERT=%s\nFAIL_SINCE=%s\nLAST_AUTOHEALED=%s\nAUTOHEAL_COUNT=%s\n' \
      "$NOW" "$fail_since" "$last_autohealed" "$autoheal_count" > "$state_file"
  fi
}

mark_ok() {
  # $1=check-name — transitions FAIL→RECOVERED notice; silent otherwise
  # Suppresses RECOVERED notice if outage lasted shorter than RECOVER_NOTIFY_MIN_SEC (t1273u/t1342u)
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status="" fail_since=0 last_autohealed=0 autoheal_count=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
    fail_since="${FAIL_SINCE:-0}"
    last_autohealed="${LAST_AUTOHEALED:-0}"
    autoheal_count="${AUTOHEAL_COUNT:-0}"
  fi
  if [[ "$last_autohealed" =~ ^[0-9]+$ && "$last_autohealed" -gt 0 ]] && (( NOW - last_autohealed >= AUTOHEALED_COOLDOWN_SEC )); then
    autoheal_count=0
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    local dur=0
    if [[ "$fail_since" =~ ^[0-9]+$ && "$fail_since" -gt 0 ]]; then
      dur=$(( NOW - fail_since ))
    fi
    if [[ "$dur" -ge "$RECOVER_NOTIFY_MIN_SEC" ]]; then
      send_alert "$name" "RECOVERED" "Check '${name}' green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ') (was FAIL for ${dur}s)."
    else
      log "OK check=${name}: recovered after ${dur}s (< RECOVER_NOTIFY_MIN_SEC=${RECOVER_NOTIFY_MIN_SEC}) — suppressing RECOVERED mail"
      printf 'STATUS=OK\nLAST_ALERT=0\nFAIL_SINCE=0\nLAST_AUTOHEALED=%s\nAUTOHEAL_COUNT=%s\n' \
        "$last_autohealed" "$autoheal_count" > "$state_file"
    fi
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\nFAIL_SINCE=0\nLAST_AUTOHEALED=%s\nAUTOHEAL_COUNT=%s\n' \
      "${LAST_ALERT:-0}" "$last_autohealed" "$autoheal_count" > "$state_file"
  fi
}

resolve_pg_container() {
  # $1=coolify.resourceName — echoes container name ("" if not found)
  docker ps --filter "label=coolify.resourceName=$1" --format '{{.Names}}' 2>/dev/null | head -n 1
}

pg_db_for_label() {
  # $1=label — echoes the psql database for this label. Per-label override
  # via PG_DB_<label> (non-alnum chars become _), else global PG_DB.
  # pg-shared needs PG_DB_pg_shared=postgres (there is no `relay` db there).
  local label="$1" var db
  var="PG_DB_$(printf '%s' "$label" | tr -c 'a-zA-Z0-9_' '_')"
  db="${!var:-}"
  if [[ -n "$db" ]]; then
    printf '%s' "$db"
  else
    printf '%s' "$PG_DB"
  fi
}

pg_container_networks() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null
}

pg_selfcheck_ok() {
  # $1=pg container $2=label — 0 (ok) only if running + (health green if
  # defined) + pg_isready. Database comes from the per-label mapping
  # (pg_db_for_label): pg-shared has no `relay` db, so a global PG_DB
  # would STANDDOWN the pg-shared branch on every run.
  local pg="$1" label="${2:-}" db state health out rc
  db="$(pg_db_for_label "$label")"
  state="$(docker inspect -f '{{.State.Running}}' "$pg" 2>/dev/null || echo missing)"
  [[ "$state" == "true" ]] || return 1
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$pg" 2>/dev/null || echo none)"
  [[ "$health" == "none" || "$health" == "healthy" ]] || return 1
  out="$(docker exec "$pg" pg_isready -U "$PGUSER" -d "$db" 2>&1)" && rc=0 || rc=$?
  [[ "$rc" -eq 0 ]] || { log "PG_SELFCHECK pg=${pg} pg_isready rc=${rc}: ${out}"; return 1; }
  return 0
}

dep_env_block() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null
}

parse_db_target() {
  # arg = env block. Echoes "<host> <port>" (port may be empty). Never
  # echoes the raw DATABASE_URL (secrets). python3 when available, pure-bash fallback.
  local block="$1" host="" port=""
  if command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    read -r host port < <(printf '%s\n' "$block" | python3 -c '
import sys
from urllib.parse import urlparse
host, port = None, None
lines = sys.stdin.read().splitlines()
for line in lines:
    if line.startswith("DATABASE_URL="):
        try:
            p = urlparse(line.split("=", 1)[1].strip())
            host = p.hostname
            port = p.port or 5432
        except Exception:
            pass
        break
if host is None:
    for line in lines:
        if line.startswith("POSTGRES_HOST="):
            host = line.split("=", 1)[1].strip()
            port = 5432
            break
for line in lines:
    if host is not None and port == 5432 and line.startswith("POSTGRES_PORT="):
        try:
            port = int(line.split("=", 1)[1].strip())
        except Exception:
            pass
print("%s %s" % (host or "", port or ""))
' 2>/dev/null)
  else
    local line val raw
    while IFS= read -r line; do
      case "$line" in
        DATABASE_URL=*)
          val="${line#DATABASE_URL=}"
          raw="${val#*//}"; raw="${raw%%/*}"; raw="${raw%%\?*}"; raw="${raw##*@}"
          host="${raw%%:*}"
          [[ "$raw" == *:* ]] && port="${raw##*:}"
          [[ -z "$port" ]] && port=5432
          break;;
        POSTGRES_HOST=*)
          host="${line#POSTGRES_HOST=}"; port=5432; break;;
      esac
    done <<< "$block"
    while IFS= read -r line; do
      case "$line" in POSTGRES_PORT=*) [[ -n "$host" ]] && port="${line#POSTGRES_PORT=}";; esac
    done <<< "$block"
  fi
  printf '%s %s' "${host:-}" "${port:-}"
}

container_has_env_key() {
  # $1=container $2=regex of env KEYS — 0 if any present (values never printed)
  dep_env_block "$1" | grep -qE "^(${2})=" || return 1
}

name_known_to_docker() {
  # $1=name $2=any container on the net — docker DNS knows the name? (0=yes)
  docker exec "$2" getent ahosts "$1" >/dev/null 2>&1
}

resolved_addrs() {
  # $1=container $2=name — prints "v4=[..] v6=[..]" summary (log-only)
  local out v4="" v6="" tok
  out="$(docker exec "$1" getent ahosts "$2" 2>/dev/null || true)"
  for tok in $out; do
    case "$tok" in
      *.*.*.*) [[ "$tok" == *:* ]] || v4="${v4}${v4:+,}$tok";;
      *:*) v6="${v6}${v6:+,}$tok";;
    esac
  done
  printf 'v4=[%s] v6=[%s]' "$v4" "$v6"
}

probe_from_container() {
  # $1=container $2=host $3=port
  # rc 0 = connect ok; rc 2 = name unresolvable inside; rc 1 = other failure;
  # rc 3 = no test tooling in image (skip, do not page)
  local c="$1" host="$2" port="$3" out rc
  if docker exec "$c" sh -c 'command -v python3 >/dev/null 2>&1'; then
    out="$(docker exec "$c" python3 -c '
import socket, sys
h, p, t = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    infos = socket.getaddrinfo(h, p, 0, socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(2)
last = None
for af, ty, pr, _cn, sa in infos:
    s = None
    try:
        s = socket.socket(af, ty, pr)
        s.settimeout(t)
        s.connect(sa)
        s.close()
        sys.exit(0)
    except OSError as e:
        last = e
        if s is not None:
            try: s.close()
            except Exception: pass
print(last)
sys.exit(1)
' "$host" "$port" "$CONNECT_TIMEOUT" 2>&1)" && rc=0 || rc=$?
    case "$rc" in
      0|2) return "$rc";;
      *) log "PROBE dep=${c} host=${host}:${port} python3 connect rc=1: ${out}"; return 1;;
    esac
  fi
  # fallback: bash /dev/tcp (no python3 in image)
  if docker exec "$c" sh -c 'command -v bash >/dev/null 2>&1'; then
    if ! name_known_to_docker "$host" "$c"; then return 2; fi
    docker exec "$c" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1 \
      && return 0 || return 1
  fi
  log "PROBE dep=${c}: neither python3 nor bash in image — cannot test, skipping"
  return 3
}

pg_container_ips() {
  # $1=pg container -> space-separated current IPv4 and IPv6 addresses
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{$v.GlobalIPv6Address}} {{end}}' "$1" 2>/dev/null | xargs
}

container_started_iso() {
  docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null
}

container_started_epoch() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "0001-01-01"* ]] && { echo 0; return; }
  date -d "$iso" +%s 2>/dev/null || echo 0
}

# Use StartedAt (not Created) so both deploys and restarts receive grace.
dependent_is_young() {
  local c="$1" started age
  started="$(container_started_epoch "$(container_started_iso "$c")")"
  (( started > 0 )) || return 1
  age=$(( $(date +%s) - started ))
  if (( age < DEP_STARTUP_GRACE_SEC )); then
    log "SKIP_YOUNG dep=${c} age=${age}s grace=${DEP_STARTUP_GRACE_SEC}s"
    return 0
  fi
  return 1
}

prune_dependent_state() {
  local c="$1" key
  key="$(safe_name "$c")"
  rm -f "${STATE_DIR}/dep-${key}.state" "${STATE_DIR}/restart-${key}.stamp"
  log "PRUNE dep=${c} reason=no_such_container removed stale state"
}

declare -A RETIRING_DEPS=()
dependent_is_retiring() {
  # Re-read lifecycle/identity at each action boundary: Coolify may retire a
  # container after docker ps, during a probe, or during a verification wait.
  local c="$1" meta status running networks created coolify project service
  local peers="" peer peer_meta peer_created peer_running reason=""
  [[ -n "${RETIRING_DEPS[$c]:-}" ]] && return 0
  if ! meta="$(docker inspect -f '{{.State.Status}}|{{.State.Running}}|{{len .NetworkSettings.Networks}}|{{.Created}}|{{with index .Config.Labels "coolify.name"}}{{.}}{{end}}|{{with index .Config.Labels "com.docker.compose.project"}}{{.}}{{end}}|{{with index .Config.Labels "com.docker.compose.service"}}{{.}}{{end}}' "$c" 2>/dev/null)"; then
    reason=missing
    prune_dependent_state "$c"
  else
    IFS='|' read -r status running networks created coolify project service <<< "$meta"
    if [[ "$status" != running || "$running" != true ]]; then
      reason="state_${status:-unknown}"
    elif [[ "$networks" == 0 ]]; then
      reason=no_networks
    else
      if [[ -n "$coolify" ]]; then
        peers="$(docker ps --filter "label=coolify.name=${coolify}" --format '{{.Names}}' 2>/dev/null)"
      fi
      if [[ -n "$project" && -n "$service" ]]; then
        peers+=" $(docker ps --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=${service}" --format '{{.Names}}' 2>/dev/null)"
      fi
      created="$(date -d "$created" +%s%N 2>/dev/null)"
      for peer in $peers; do
        [[ "$peer" == "$c" ]] && continue
        peer_meta="$(docker inspect -f '{{.Created}}|{{.State.Running}}' "$peer" 2>/dev/null)" || continue
        IFS='|' read -r peer_created peer_running <<< "$peer_meta"
        [[ "$peer_running" == true ]] || continue
        peer_created="$(date -d "$peer_created" +%s%N 2>/dev/null)"
        if [[ -n "$created" && -n "$peer_created" ]] && (( peer_created > created )); then
          reason="newer_container_${peer}"
          break
        fi
      done
    fi
  fi
  [[ -n "$reason" ]] || return 1
  RETIRING_DEPS[$c]="$reason"
  log "SKIP_RETIRING dep=${c} reason=${reason}"
  return 0
}

is_web_container() {
  # $1=container name — 0 if HTTP server (web-* / gunicorn / uvicorn), 1 if worker
  [[ "$1" == web-* ]] && return 0
  local cmd
  cmd="$(docker inspect -f '{{join .Config.Cmd " "}}' "$1" 2>/dev/null || true)"
  [[ "$cmd" == *gunicorn* || "$cmd" == *uvicorn* || "$cmd" == *daphne* ]] && return 0
  return 1
}

resolve_target_pg_container() {
  # $1=host from DATABASE_URL $2=default pg container $3=default pg name
  local host="$1" pg="$2" pgname="$3" state
  [[ "$host" == "$pg" || "$host" == "$pgname" ]] && { printf '%s' "$pg"; return; }
  state="$(docker inspect -f '{{.State.Running}}' "$host" 2>/dev/null || echo missing)"
  if [[ "$state" == "true" ]]; then
    printf '%s' "$host"
  else
    printf '%s' "$pg"
  fi
}

check_active_socket_peers() {
  # $1=dep_container $2=port $3=space-separated allowed PG IPs
  # Echoes "peers=<N>" on rc=0; echoes "stale_socket_peer=<bad_ip>(expected:<allowed>)" on rc=1
  local c="$1" port="$2" allowed="$3" out rc
  [[ -z "${allowed// /}" ]] && { printf 'peers=skip'; return 0; }
  if ! docker exec "$c" sh -c 'command -v python3 >/dev/null 2>&1'; then
    printf 'peers=no-py3'
    return 0
  fi
  out="$(docker exec "$c" python3 -c '
import ipaddress, socket, struct, sys
target_port = int(sys.argv[1])
allowed = set()
for raw in sys.argv[2].split():
    try:
        allowed.add(ipaddress.ip_address(raw))
    except ValueError:
        pass
for lb in ("127.0.0.1", "::1"):
    allowed.add(ipaddress.ip_address(lb))
seen = set()
bad = set()
def scan(path, family):
    try:
        with open(path) as f:
            next(f, None)
            for line in f:
                parts = line.split()
                if len(parts) < 4:
                    continue
                rem_hex, state = parts[2], parts[3]
                # 01 = TCP_ESTABLISHED, 02 = TCP_SYN_SENT
                if state not in ("01", "02"):
                    continue
                ip_hex, port_hex = rem_hex.split(":")
                if int(port_hex, 16) != target_port:
                    continue
                if family == socket.AF_INET:
                    raw_ip = socket.inet_ntop(socket.AF_INET, struct.pack("<I", int(ip_hex, 16)))
                else:
                    b = bytes.fromhex(ip_hex)
                    b_be = b"".join(struct.pack("<I", struct.unpack(">I", b[i:i+4])[0]) for i in range(0, 16, 4))
                    raw_ip = socket.inet_ntop(socket.AF_INET6, b_be)
                ip_obj = ipaddress.ip_address(raw_ip)
                if getattr(ip_obj, "ipv4_mapped", None) is not None:
                    ip_obj = ip_obj.ipv4_mapped
                seen.add(str(ip_obj))
                if ip_obj not in allowed:
                    bad.add(str(ip_obj))
    except Exception:
        pass
scan("/proc/1/net/tcp", socket.AF_INET)
scan("/proc/1/net/tcp6", socket.AF_INET6)
if bad:
    exp = ",".join(sorted(str(x) for x in allowed if not x.is_loopback))
    print("stale_socket_peer=%s(expected:%s)" % (",".join(sorted(bad)), exp))
    sys.exit(1)
print("peers=%d" % len(seen))
sys.exit(0)
' "$port" "$allowed" 2>/dev/null)" && rc=0 || rc=$?
  printf '%s' "${out:-peers=0}"
  return "$rc"
}

classify_db_errors() {
  # stdin: worker log lines (optionally `docker logs --timestamps` prefixed)
  # after the latest startup banner. Echoes one line:
  #   <verdict>|<class>|<error_ts>|<error_line>|<last_success_ts>|<first_pending_ts>
  # verdicts:
  #   clean           no DB exception lines
  #   conn            a connection-class DB error came AFTER the last
  #                   successful unit of work -> restart (unchanged policy)
  #   handled_pending only non-connection DB errors (handled DeadlockDetected /
  #                   SerializationFailure, or an unrecognised OperationalError)
  #                   after the last success -> the no-progress logic decides
  #   recovered       every DB error is followed by a later success
  # Successful unit of work: db_worker `state=SUCCESSFUL`, or an SQS ingress
  # batch with deleted>=1 (messages are durably enqueued before delete).
  # Retry log lines ("retrying ...", "transient DB error") are not failures:
  # the app is handling them; only the resulting outcome counts.
  awk '
    {
      line = $0; ts = ""
      if (match(line, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /)) {
        ts = substr(line, 1, RLENGTH - 1); line = substr(line, RLENGTH + 1)
      }
      low = tolower(line)
      if (low ~ /retrying|transient db error/) next
      if (line ~ /state=SUCCESSFUL/ || line ~ /received=[0-9]+ deleted=[1-9]/) {
        ok_ts = ts; last_ok = NR; next
      }
      if (line !~ /(psycopg2?|django\.db\.utils)(\.errors)?\.(OperationalError|InterfaceError|DeadlockDetected|SerializationFailure)/) next
      if (line ~ /DeadlockDetected|SerializationFailure/ || low ~ /deadlock detected|could not serialize access/) {
        cls = "handled"
      } else if (line ~ /InterfaceError/ || low ~ /could not translate host name|name or service not known|temporary failure in name resolution|connection refused|server closed the connection|connection already closed|connection is closed|connection to server|could not connect|connection timed out|timeout expired|terminating connection|connection reset|no route to host|network is unreachable|ssl syscall error|ssl connection has been closed|could not receive data from server|could not send data to server|database system is (starting up|shutting down|in recovery mode)|remaining connection slots|too many clients/) {
        cls = "conn"
      } else {
        # Unrecognised OperationalError: not proven connection-class; handled
        # like a per-task error (restart only via the no-progress logic).
        cls = "other"
      }
      n++; e_nr[n] = NR; e_cls[n] = cls; e_ts[n] = ts; e_line[n] = line
    }
    END {
      if (n == 0) { print "clean||||" ok_ts "|"; exit }
      pick = 0; hpick = 0; first_ts = ""; first_seen = 0
      for (i = 1; i <= n; i++) {
        if (e_nr[i] < last_ok) continue
        if (e_cls[i] == "conn") { pick = i; continue }
        hpick = i
        # Grace runs from the FIRST non-connection error after the last
        # success, so repeated deadlocks cannot keep resetting it.
        if (!first_seen) { first_seen = 1; first_ts = e_ts[i] }
      }
      if (pick) { v = "conn" }
      else if (hpick) { v = "handled_pending"; pick = hpick }
      else { v = "recovered"; pick = n }
      gsub(/\|/, "/", e_line[pick])
      printf "%s|%s|%s|%s|%s|%s\n", v, e_cls[pick], e_ts[pick], e_line[pick], (ok_ts == "" ? "none" : ok_ts), first_ts
    }
  '
}

parse_db_name() {
  # arg = env block. Echoes the database name from DATABASE_URL (or
  # POSTGRES_DB); never echoes credentials.
  local block="$1" line val
  while IFS= read -r line; do
    case "$line" in
      DATABASE_URL=*)
        val="${line#DATABASE_URL=}"; val="${val#*//}"
        [[ "$val" == */* ]] || return 0
        val="${val#*/}"; val="${val%%\?*}"
        printf '%s' "$val"; return 0;;
    esac
  done <<< "$block"
  while IFS= read -r line; do
    case "$line" in POSTGRES_DB=*) printf '%s' "${line#POSTGRES_DB=}"; return 0;; esac
  done <<< "$block"
}

# Set per label by watch_pg: the Postgres container and the database whose
# django_tasks_database_dbtaskresult backlog check_pg_worker_progress watches
# (empty when that SQL check is disabled or the table does not exist).
LABEL_PG=""
QUEUE_SQL_DB=""
# The ready-backlog query of progress-task-queues; also run by watch_pg to
# decide whether that check really covers a database.
QUEUE_BACKLOG_SQL="
      SELECT queue_name || '|' || COUNT(*) || '|' || COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(GREATEST(enqueued_at, run_after))))::int, 0)
      FROM django_tasks_database_dbtaskresult
      WHERE status = 'READY' AND run_after <= NOW()
      GROUP BY queue_name;"

worker_queue_sql_covered() {
  # $1=dep $2=target pg container $3=dep database. 0 when the SQL ready-backlog
  # check (progress-task-queues) watches this db_worker's queue and would pick
  # this container as the worker to restart.
  local c="$1" target_pg="$2" dep_db="$3"
  [[ "$PROGRESS_SQL_CHECKS" == "1" && -n "$QUEUE_SQL_DB" && -n "$dep_db" ]] || return 1
  [[ "$target_pg" == "$LABEL_PG" && "$dep_db" == "$QUEUE_SQL_DB" ]] || return 1
  [[ "$c" == provider-events-worker-* || "$c" == worker-* ]] || return 1
  return 0
}

probe_worker_progress() {
  # $1=dep_container $2=target_pg_container $3=port
  # Verifies running-worker health beyond fresh sibling TCP (t1218u):
  #   a) active :5432 TCP sockets in /proc/1/net/tcp{,6} match live PG IPs
  #   b) background workers do not pre-date a PG container recreate
  #   c) ses-ingress latest batch did not fail 100% (deleted=0 failed>0)
  #   d) background workers have no uncaught DB OperationalError/InterfaceError
  #      after their latest startup banner
  #   e) DB errors are classified (classify_db_errors): connection-class
  #      errors after the last successful unit of work fail; handled per-task
  #      errors (deadlock / serialization failure) do not (AC-B1).
  # $4=database name the dependent uses (for SQL queue-check coverage).
  # Echoes summary string; returns 0 if healthy, 4 if stale/stuck.
  [[ "$PROGRESS_CHECKS" == "1" ]] || { printf 'progress=disabled'; return 0; }
  local c="$1" target_pg="$2" port="$3" dep_db="${4:-}"
  local pg_ips peer_out dep_iso pg_iso dep_epoch pg_epoch logs last_batch
  pg_ips="$(pg_container_ips "$target_pg")"
  if ! peer_out="$(check_active_socket_peers "$c" "$port" "$pg_ips")"; then
    printf 'progress=FAIL(%s)' "$peer_out"
    return 4
  fi

  if is_web_container "$c"; then
    printf 'progress=ok(%s,role=web)' "$peer_out"
    return 0
  fi

  dep_iso="$(container_started_iso "$c")"
  pg_iso="$(container_started_iso "$target_pg")"
  dep_epoch="$(container_started_epoch "$dep_iso")"
  pg_epoch="$(container_started_epoch "$pg_iso")"

  if [[ "$RESTART_WORKERS_OLDER_THAN_PG" == "1" ]] && (( dep_epoch > 0 && pg_epoch > 0 )) && (( pg_epoch - dep_epoch > PG_RECREATE_GRACE_SEC )); then
    printf 'progress=FAIL(worker_older_than_pg:dep_started=%s<pg_started=%s)' "$dep_iso" "$pg_iso"
    return 4
  fi

  # --timestamps: classify_db_errors needs the time of each DB error and of
  # the last successful unit of work (ordering + handled-error grace).
  if [[ -n "$dep_iso" && "$dep_iso" != "0001-01-01"* ]]; then
    logs="$(docker logs --timestamps --since "$dep_iso" --tail 500 "$c" 2>&1 || true)"
  else
    logs="$(docker logs --timestamps --tail 500 "$c" 2>&1 || true)"
  fi

  local tail_after_start="$logs"
  if printf '%s\n' "$logs" | grep -qE 'Starting (worker|.*ingress drain|recipient-list import worker|.*callback dispatcher)'; then
    tail_after_start="$(printf '%s\n' "$logs" | awk '
      /Starting (worker|.*ingress drain|recipient-list import worker|.*callback dispatcher)/ { buf=""; next }
      { buf = buf $0 "\n" }
      END { printf "%s", buf }
    ')"
  fi
  # DB errors after the latest startup banner (AC-B1, 2026-10-27 deadlock
  # false positive). See classify_db_errors for the verdicts.
  local db_note="" verdict err_cls err_ts err_text ok_ts first_ts
  IFS='|' read -r verdict err_cls err_ts err_text ok_ts first_ts < <(printf '%s\n' "$tail_after_start" | classify_db_errors)
  # Parens/commas would break the progress=...(a,b) summary and the WARN key.
  err_text="$(printf '%s' "${err_text:-}" | tr -s '[:space:](),' '_' | cut -c1-80)"
  case "${verdict:-clean}" in
    conn)
      printf 'progress=FAIL(worker_db_error_since_start:%s)' "$err_text"
      return 4
      ;;
    recovered)
      db_note="db_error_recovered=${err_cls}:${err_text}@${err_ts:-unknown},later_success=${ok_ts:-unknown}"
      ;;
    handled_pending)
      local err_epoch=0 err_age=-1 since_file stored=0 ok_epoch=0
      [[ -n "$first_ts" ]] && err_epoch="$(date -d "$first_ts" +%s 2>/dev/null || echo 0)"
      [[ -n "$ok_ts" && "$ok_ts" != none ]] && ok_epoch="$(date -d "$ok_ts" +%s 2>/dev/null || echo 0)"
      # Remember when this no-success stretch began: older errors can leave
      # the --tail window while new ones keep arriving. Ignored when it
      # predates the current container start (new lifecycle).
      since_file="${STATE_DIR}/pending-dep-$(safe_name "$c").since"
      [[ -f "$since_file" ]] && stored="$(tr -cd '0-9' < "$since_file")"
      stored="${stored:-0}"
      if (( stored > 0 && stored >= dep_epoch && stored >= ok_epoch )) && (( err_epoch == 0 || stored < err_epoch )); then
        err_epoch="$stored"
      elif (( err_epoch > 0 )); then
        printf '%s\n' "$err_epoch" > "$since_file"
      fi
      (( err_epoch > 0 )) && err_age=$(( $(date +%s) - err_epoch ))
      if worker_queue_sql_covered "$c" "$target_pg" "$dep_db"; then
        # No task since the handled error: the SQL ready-backlog check
        # (progress-task-queues) owns "no progress" for this worker and
        # restarts it if due READY tasks get stuck.
        db_note="handled_db_error=${err_cls}:${err_text}@${err_ts:-unknown},later_success=none,deferred_to=progress-task-queues"
      elif (( err_age >= 0 && err_age < HANDLED_DB_ERROR_GRACE_SEC )); then
        db_note="handled_db_error=${err_cls}:${err_text}@${err_ts},later_success=none,grace=${err_age}s<${HANDLED_DB_ERROR_GRACE_SEC}s"
      else
        # No queue check covers this loop and no progress within the grace
        # window (or unknown error time): treat as no progress.
        printf 'progress=FAIL(handled_db_error_no_progress:%s@%s,first_since_success=%s,age=%ss)' "$err_text" "${err_ts:-unknown}" "${first_ts:-unknown}" "$err_age"
        return 4
      fi
      ;;
  esac
  [[ "${verdict:-clean}" == handled_pending ]] || rm -f "${STATE_DIR}/pending-dep-$(safe_name "$c").since"
  [[ -n "$db_note" ]] && peer_out="${peer_out},${db_note}"

  if [[ "$c" == ses-ingress* ]]; then
    last_batch="$(printf '%s\n' "$logs" | grep -oE 'received=[0-9]+ deleted=[0-9]+ failed=[0-9]+' | tail -n 1 || true)"
    if [[ -n "$last_batch" ]]; then
      if [[ "$last_batch" =~ deleted=0[[:space:]]+failed=[1-9] || "$last_batch" =~ failed=[1-9] ]]; then
        local recent_deleted
        recent_deleted="$(printf '%s\n' "$logs" | grep -oE 'received=[0-9]+ deleted=[0-9]+ failed=[0-9]+' | grep -v 'deleted=0' | wc -l)"
        # Distinguish real connectivity failure (TCP probe, socket peers, or DB errors caught above)
        # from per-message processing failures (deleted>0 recently or isolated failed=1).
        # Per-message failures do NOT send FAIL and do NOT restart container (t1342u).
        if (( recent_deleted > 0 )) || [[ "$last_batch" =~ failed=1([[:space:]]|$) ]]; then
          printf 'progress=ok(%s,ses_per_msg_fail=%s)' "$peer_out" "${last_batch// /,}"
          return 0
        fi
        printf 'progress=FAIL(ses_ingress_batch_failed:%s)' "${last_batch// /,}"
        return 4
      fi
      printf 'progress=ok(%s,ses_last=%s)' "$peer_out" "${last_batch// /,}"
      return 0
    fi
  fi

  if [[ -n "$db_note" ]]; then
    printf 'progress=ok(%s)' "$peer_out"
  else
    printf 'progress=ok(%s,logs=clean)' "$peer_out"
  fi
  return 0
}

check_pg_worker_progress() {
  # $1=label $2=pg_container $3=space-separated dependent containers
  [[ "$PROGRESS_SQL_CHECKS" == "1" ]] || return 0
  local label="$1" pg="$2" deps="$3" db
  db="$(pg_db_for_label "$label")"
  docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT 1" >/dev/null 2>&1 || return 0

  # 1) Relay scheduler heartbeat freshness
  local has_hb
  has_hb="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT to_regclass('public.relay_scheduler_heartbeat') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$has_hb" == "t" ]]; then
    local sched_c="" d hb_age hb_pre hb_check="progress-scheduler-heartbeat"
    for d in $deps; do
      [[ "$d" == scheduler-* ]] && { sched_c="$d"; break; }
    done
    hb_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MAX(ticked_at)))::int, 999999) FROM relay_scheduler_heartbeat;" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$sched_c" ]] && { dependent_is_retiring "$sched_c" || dependent_is_young "$sched_c"; }; then
      : # Leave existing alert state untouched during startup.
    elif [[ "$hb_age" =~ ^-?[0-9]+$ ]]; then
      (( hb_age < 0 )) && hb_age=0
      if (( hb_age <= SCHEDULER_MAX_AGE_SEC )); then
        log "OK check=${hb_check} pg=${label} scheduler=${sched_c:-none} age=${hb_age}s max=${SCHEDULER_MAX_AGE_SEC}s"
        mark_ok "$hb_check"
      else
        log "FAIL check=${hb_check} pg=${label} scheduler=${sched_c:-none} age=${hb_age}s max=${SCHEDULER_MAX_AGE_SEC}s"
        hb_pre="$hb_age"
        if [[ -n "$sched_c" ]] && restart_dependent "$sched_c"; then
          sleep "$RESTART_VERIFY_WAIT"
          dependent_is_retiring "$sched_c" && return
          hb_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MAX(ticked_at)))::int, 999999) FROM relay_scheduler_heartbeat;" 2>/dev/null | tr -d '[:space:]')"
          dependent_is_retiring "$sched_c" && return
          FAILED=1
          if [[ "$hb_age" =~ ^-?[0-9]+$ ]] && (( hb_age <= SCHEDULER_MAX_AGE_SEC )); then
            log "HEALED check=${hb_check} scheduler=${sched_c} age=${hb_age}s after restart"
            send_alert "$hb_check" "AUTOHEALED" \
              "Relay scheduler heartbeat (relay_scheduler_heartbeat.ticked_at) on $(hostname) was stale while fresh TCP probe was green. Auto-restarted ${sched_c}.

Pre-restart reason: heartbeat age=${hb_pre}s > max ${SCHEDULER_MAX_AGE_SEC}s
Post-restart result: heartbeat age=${hb_age}s (ok)"
          else
            log "STILLFAIL check=${hb_check} scheduler=${sched_c} age=${hb_age:-unknown}s after restart"
            send_alert "$hb_check" "FAIL" \
              "Relay scheduler heartbeat on $(hostname) remains stale after restarting ${sched_c}.

Pre-restart reason: heartbeat age=${hb_pre}s > max ${SCHEDULER_MAX_AGE_SEC}s
Post-restart result: heartbeat age=${hb_age:-unknown}s (still stale)"
          fi
        else
          [[ "$?" -eq 2 ]] && return
          [[ -n "$sched_c" ]] && dependent_is_retiring "$sched_c" && return
          FAILED=1
          send_alert "$hb_check" "FAIL" \
            "Relay scheduler heartbeat on $(hostname) is stale; scheduler=${sched_c:-not-found}.

Pre-restart reason: heartbeat age=${hb_age}s > max ${SCHEDULER_MAX_AGE_SEC}s
Post-restart result: not restarted (cooldown, DRY_RUN or no scheduler container)"
        fi
      fi
    fi
  fi

  # 2) django_tasks_database_dbtaskresult ready-backlog freshness
  local has_tasks
  has_tasks="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT to_regclass('public.django_tasks_database_dbtaskresult') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$has_tasks" == "t" ]]; then
    local q_rows last_pe_ok q_check="progress-task-queues" q_failed=0 q_young=0 q_unknown=0
    q_rows="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "$QUEUE_BACKLOG_SQL" 2>/dev/null)" || {
      q_rows=""
      q_unknown=1
      log "WARN check=${q_check} pg=${label}: ready-backlog query failed; queue progress unknown this run"
    }
    last_pe_ok="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "
      SELECT COALESCE(TO_CHAR(MAX(finished_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), 'none')
      FROM django_tasks_database_dbtaskresult
      WHERE status = 'SUCCESSFUL' AND queue_name = 'provider-events';
    " 2>/dev/null | tr -d '[:space:]')"
    local line qname qcnt qage qworker d
    for d in $deps; do
      if [[ "$d" == provider-events-worker-* || "$d" == worker-* ]] && dependent_is_young "$d"; then
        q_young=1
      fi
    done
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r qname qcnt qage <<< "$line"
      [[ "$qage" =~ ^-?[0-9]+$ ]] || continue
      if (( qage > TASK_QUEUE_MAX_READY_AGE_SEC )); then
        # Several stacks can share one Postgres (relay + relay_dev): pick the
        # worker whose DATABASE_URL uses this database; fall back to a worker
        # with no parseable database name.
        qworker=""
        local qfallback="" ddb
        for d in $deps; do
          if [[ ( "$qname" == "provider-events" && "$d" == provider-events-worker-* ) || ( "$qname" == "default" && "$d" == worker-* ) ]]; then
            ddb="$(parse_db_name "$(dep_env_block "$d")")"
            if [[ "$ddb" == "$db" ]]; then qworker="$d"; break; fi
            [[ -z "$ddb" && -z "$qfallback" ]] && qfallback="$d"
          fi
        done
        qworker="${qworker:-$qfallback}"
        if [[ -n "$qworker" ]] && { dependent_is_retiring "$qworker" || dependent_is_young "$qworker"; }; then
          q_young=1
          continue
        fi
        log "FAIL check=${q_check} pg=${label} queue=${qname} ready=${qcnt} oldest_ready=${qage}s max=${TASK_QUEUE_MAX_READY_AGE_SEC}s worker=${qworker:-none}"
        if [[ -n "$qworker" ]] && restart_dependent "$qworker"; then
          sleep "$RESTART_VERIFY_WAIT"
          dependent_is_retiring "$qworker" && { q_young=1; continue; }
          local new_age
          new_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "
            SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(GREATEST(enqueued_at, run_after))))::int, 0)
            FROM django_tasks_database_dbtaskresult
            WHERE status = 'READY' AND run_after <= NOW() AND queue_name = '${qname//\'/}';
          " 2>/dev/null | tr -d '[:space:]')"
          dependent_is_retiring "$qworker" && { q_young=1; continue; }
          q_failed=1
          FAILED=1
          if [[ "$new_age" =~ ^-?[0-9]+$ ]] && (( new_age <= TASK_QUEUE_MAX_READY_AGE_SEC )); then
            log "HEALED check=${q_check} queue=${qname} worker=${qworker} oldest_ready=${new_age}s after restart"
            send_alert "$q_check" "AUTOHEALED" \
              "Relay task queue '${qname}' on $(hostname) had due READY tasks stuck while fresh TCP probe was green. Auto-restarted ${qworker}.

Pre-restart reason: ${qcnt} due READY task(s), oldest_ready=${qage}s > max ${TASK_QUEUE_MAX_READY_AGE_SEC}s
Post-restart result: oldest_ready=${new_age}s (ok)"
          else
            log "STILLFAIL check=${q_check} queue=${qname} worker=${qworker} oldest_ready=${new_age:-unknown}s after restart"
            send_alert "$q_check" "FAIL" \
              "Relay task queue '${qname}' on $(hostname) still has due READY task(s) stuck after restarting ${qworker}.

Pre-restart reason: ${qcnt} due READY task(s), oldest_ready=${qage}s > max ${TASK_QUEUE_MAX_READY_AGE_SEC}s
Post-restart result: oldest_ready=${new_age:-unknown}s (still stuck)"
          fi
        else
          [[ "$?" -eq 2 ]] && { q_young=1; continue; }
          [[ -n "$qworker" ]] && dependent_is_retiring "$qworker" && { q_young=1; continue; }
          q_failed=1
          FAILED=1
          send_alert "$q_check" "FAIL" \
            "Relay task queue '${qname}' on $(hostname) has due READY task(s) stuck; worker=${qworker:-not-found}.

Pre-restart reason: ${qcnt} due READY task(s), oldest_ready=${qage}s > max ${TASK_QUEUE_MAX_READY_AGE_SEC}s
Post-restart result: not restarted (cooldown, DRY_RUN or no worker container)"
        fi
      fi
    done <<< "$q_rows"
    if (( q_failed == 0 && q_young == 0 && q_unknown == 0 )); then
      log "OK check=${q_check} pg=${label} stuck_ready=0 max_age=${TASK_QUEUE_MAX_READY_AGE_SEC}s last_provider_event_ok=${last_pe_ok:-none}"
      mark_ok "$q_check"
    fi
  fi
}

restart_dependent() {
  # 0=restarted, 1=cooldown/dry-run/error, 2=retired/removed (no alert).
  local c="$1" stamp="${STATE_DIR}/restart-$(safe_name "$1").stamp" last=0 restart_out
  dependent_is_retiring "$c" && return 2
  dependent_is_young "$c" && return 1
  [[ -f "$stamp" ]] && last="$(tr -d '[:space:]' < "$stamp")"
  last="${last:-0}"
  if (( NOW - last < RESTART_COOLDOWN_SEC )); then
    log "RESTART dep=${c}: cooldown active ($(( NOW - last ))s < ${RESTART_COOLDOWN_SEC}s) — skipping restart"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "RESTART dep=${c}: DRY_RUN=1 — would restart"
    return 1
  fi
  log "RESTART dep=${c}: restarting (stale DNS/conn/worker-progress remedy, t1205u/t1218u)"
  if ! restart_out="$(docker restart "$c" 2>&1)"; then
    # Do not print arbitrary daemon output. A removal during this call is
    # normal rolling-deploy cleanup, not a failed auto-heal.
    if [[ "${restart_out,,}" == *"no such container"* ]]; then
      prune_dependent_state "$c"
      RETIRING_DEPS[$c]=missing
      return 2
    fi
    dependent_is_retiring "$c" && return 2
    log "RESTART dep=${c}: docker restart FAILED"
    return 1
  fi
  printf '%s\n' "$NOW" > "$stamp"
  return 0
}

probe_rc_desc() {
  case "$1" in
    0) printf 'connect ok';;
    1) printf 'connect failed';;
    2) printf 'name unresolvable';;
    3) printf 'no probe tooling';;
    4) printf 'worker-progress check failed';;
    *) printf 'unknown';;
  esac
}

warn_handled_db_error() {
  # $1=dep $2=progress summary. Handled per-task DB error (deadlock /
  # serialization failure) or a DB error followed by later successful work:
  # no restart (AC-B1), but log a WARN line and send a low-priority notice
  # once per distinct error (keyed by the error's log timestamp + text).
  # The notice is written to a .pending file first, so an undelivered or
  # rate-limited one is retried by flush_pending_warns even after the error
  # has left the log window.
  local c="$1" prog="$2" note key warn_check pending last_key="" prev_note=""
  note="$(printf '%s' "$prog" | grep -oE '(handled_db_error|db_error_recovered)=[^)]*' | head -n 1)"
  [[ -n "$note" ]] || return 0
  log "WARN check=dep-$(safe_name "$c") dep=${c}: DB error seen but worker not restarted (${note})"
  warn_check="warn-dep-$(safe_name "$c")"
  key="$(printf '%s' "$note" | sed -E 's/,(later_success|deferred_to|grace)=.*$//')"
  pending="${STATE_DIR}/${warn_check}.pending"
  [[ -f "${STATE_DIR}/${warn_check}.key" ]] && last_key="$(cat "${STATE_DIR}/${warn_check}.key" 2>/dev/null)"
  [[ "$key" == "$last_key" ]] && return 0
  if [[ -f "$pending" ]]; then
    # Unsent older notices are folded into the new one, never dropped.
    local old_key old_note old_prev
    { IFS= read -r old_key; IFS= read -r _; IFS= read -r old_note; IFS= read -r _; IFS= read -r old_prev; } < "$pending"
    prev_note="${old_prev:-}"
    if [[ "${old_key:-}" != "$key" && -n "${old_note:-}" ]]; then
      prev_note="${prev_note:+${prev_note}; }${old_note}"
    fi
    prev_note="$(printf '%s' "$prev_note" | tail -c 1500)"
  fi
  printf '%s\n%s\n%s\n%s\n%s\n' "$key" "$c" "$note" "$prog" "$prev_note" > "$pending"
  send_pending_warn "$pending"
}

declare -A WARN_TRIED=()
send_pending_warn() {
  # $1=pending file (lines: key, container, note, progress, earlier unsent note)
  # At most one delivery attempt per pending file per run.
  local pending="$1" key c note prog prev warn_check extra=""
  [[ -n "${WARN_TRIED[$pending]:-}" ]] && return 0
  WARN_TRIED[$pending]=1
  { IFS= read -r key; IFS= read -r c; IFS= read -r note; IFS= read -r prog; IFS= read -r prev; } < "$pending"
  [[ -n "${key:-}" && -n "${c:-}" ]] || { rm -f "$pending"; return 0; }
  warn_check="warn-dep-$(safe_name "$c")"
  [[ -n "${prev:-}" ]] && extra=$'\n'"Earlier unsent notice: ${prev}"
  if send_alert "$warn_check" "WARN handled DB error" \
    "${c} on $(hostname) logged a database error that the watchdog does NOT treat as a stale connection, so the container was not restarted (low priority; no action needed unless this repeats).

Observed: ${note}
Progress check: ${prog}${extra}

Handled per-task errors (deadlock, serialization failure) abort one task; the worker keeps processing. If no later task succeeds, the SQL ready-backlog check (progress-task-queues) or the ${HANDLED_DB_ERROR_GRACE_SEC}s no-progress grace still restarts the worker." "low"; then
    printf '%s\n' "$key" > "${STATE_DIR}/${warn_check}.key"
    rm -f "$pending"
  fi
}

flush_pending_warns() {
  # Retry low-priority notices that earlier runs could not send.
  local f
  for f in "$STATE_DIR"/warn-dep-*.pending; do
    [[ -f "$f" ]] || continue
    send_pending_warn "$f"
  done
}

watch_pg() {
  # $1=coolify.resourceName label
  local label="$1" pg pgname deps c dep_nets n nets pg_nets target host port rc env_block
  local dep_check target_pg prog_out dep_db pre_reason post_result
  pg="$(resolve_pg_container "$label")"
  if [[ -z "$pg" ]]; then
    log "FAIL pg=${label}: no container with label coolify.resourceName=${label}"
    send_alert "pg-${label}" "FAIL" \
      "No running container with label coolify.resourceName=${label} on $(hostname). Postgres gone? Watchdog cannot protect dependents."
    FAILED=1
    return
  fi
  pgname="$(docker inspect -f '{{.Name}}' "$pg" 2>/dev/null | sed 's#^/##')"
  if ! pg_selfcheck_ok "$pg" "$label"; then
    # Real PG outage — healthcheck owns the page; restarting apps would only churn.
    log "STANDDOWN pg=${pg} (${label}): Postgres self-check failed — no dependent restarts this run (coolify-healthcheck pages for PG outages)"
    EXIT_CODE=2
    return
  fi
  pg_nets="$(pg_container_networks "$pg")"
  log "OK pg=${label} container=${pg} name=${pgname} nets=[${pg_nets% }]"
  LABEL_PG="$pg"
  QUEUE_SQL_DB=""
  if [[ "$PROGRESS_SQL_CHECKS" == "1" ]]; then
    local label_db
    label_db="$(pg_db_for_label "$label")"
    # Coverage only when the ready-backlog query itself runs: a failing
    # query would make progress-task-queues blind, so handled errors must
    # then fall back to the grace/no-progress restart.
    if [[ "$(docker exec "$pg" psql -U "$PGUSER" -d "$label_db" -tAqc "SELECT to_regclass('public.django_tasks_database_dbtaskresult') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')" == "t" ]] \
      && docker exec "$pg" psql -U "$PGUSER" -d "$label_db" -tAqc "$QUEUE_BACKLOG_SQL" >/dev/null 2>&1; then
      QUEUE_SQL_DB="$label_db"
    fi
  fi

  deps=""
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    [[ "$c" == "$pg" ]] && continue
    [[ "$c" =~ $DEPENDENT_EXCLUDE ]] && continue
    container_has_env_key "$c" 'DATABASE_URL|POSTGRES_HOST' || continue
    dependent_is_retiring "$c" && continue
    dep_nets="$(pg_container_networks "$c")"
    nets=""
    for n in $dep_nets; do
      [[ " $pg_nets " == *" $n "* ]] && nets="$nets $n"
    done
    [[ -z "${nets// /}" ]] && continue
    deps="$deps $c"
  done
  if [[ -z "${deps// /}" ]]; then
    log "WARN pg=${label}: no dependent containers found (env-gated: DATABASE_URL/POSTGRES_HOST)"
    return
  fi

  for c in $deps; do
    dependent_is_retiring "$c" && continue
    dependent_is_young "$c" && continue
    env_block="$(dep_env_block "$c")"
    target="$(parse_db_target "$env_block")"
    dep_db="$(parse_db_name "$env_block")"
    host="${target%% *}"; port="${target##* }"
    [[ -z "$port" ]] && port=5432
    dep_check="dep-$(safe_name "$c")"
    if [[ -z "$host" ]]; then
      log "WARN dep=${c}: DB env present but no host parseable — skipping"
      continue
    fi
    target_pg="$(resolve_target_pg_container "$host" "$pg" "$pgname")"
    prog_out="progress=n/a"
    probe_from_container "$c" "$host" "$port"; rc=$?
    if [[ "$rc" -eq 2 ]]; then
      log "DNS_RECHECK dep=${c} initial_rc=2 wait=${DNS_RECHECK_WAIT_SEC}s"
      sleep "$DNS_RECHECK_WAIT_SEC"
      # A deploy/restart may have happened while waiting.
      dependent_is_retiring "$c" && continue
      dependent_is_young "$c" && continue
      probe_from_container "$c" "$host" "$port"; rc=$?
      log "DNS_RECHECK dep=${c} rc=${rc} $(resolved_addrs "$c" "$host")"
    fi
    dependent_is_retiring "$c" && continue
    if [[ "$rc" -eq 0 ]]; then
      if prog_out="$(probe_worker_progress "$c" "$target_pg" "$port" "$dep_db")"; then
        dependent_is_retiring "$c" && continue
        log "OK check=${dep_check} dep=${c} host=${host}:${port} $(resolved_addrs "$c" "$host") ${prog_out}"
        mark_ok "$dep_check"
        warn_handled_db_error "$c" "$prog_out"
        continue
      else
        rc=4
      fi
    fi
    if [[ "$rc" -eq 3 ]]; then
      continue  # no tooling in image — logged, no false page
    fi
    if [[ "$target_pg" != "$pg" ]] && ! docker exec "$target_pg" pg_isready -U "$PGUSER" >/dev/null 2>&1; then
      log "STANDDOWN dep=${c}: target pg=${target_pg} self-check failed — skipping dependent restart"
      EXIT_CODE=2
      continue
    fi
    dependent_is_retiring "$c" && continue
    log "FAIL check=${dep_check} dep=${c} host=${host}:${port} rc=${rc} $(resolved_addrs "$c" "$host") ${prog_out}"
    pre_reason="probe rc=${rc} ($(probe_rc_desc "$rc")), ${prog_out}"
    if [[ "$host" != "$pgname" && "$host" != "$pg" ]] && ! name_known_to_docker "$host" "$pg"; then
      # Stale NAME (PG redeployed under a new uuid) — restart cannot fix.
      dependent_is_retiring "$c" && continue
      FAILED=1
      send_alert "$dep_check" "FAIL" \
        "${c} on $(hostname) references Postgres name '${host}' which docker DNS no longer resolves.
pg-${label} is now container '${pg}' (name=${pgname}) and is healthy — the app env still points at the old uuid name.
Fix: redeploy the app in Coolify (picks up current DATABASE_URL host) or update its DATABASE_URL/POSTGRES_HOST.
No restart attempted (would not help)."
      continue
    fi
    if restart_dependent "$c"; then
      sleep "$RESTART_VERIFY_WAIT"
      dependent_is_retiring "$c" && continue
      probe_from_container "$c" "$host" "$port" && rc=0 || rc=$?
      dependent_is_retiring "$c" && continue
      if [[ "$rc" -eq 0 ]]; then
        if prog_out="$(probe_worker_progress "$c" "$target_pg" "$port" "$dep_db")"; then
          rc=0
        else
          rc=4
        fi
      fi
      dependent_is_retiring "$c" && continue
      FAILED=1
      post_result="probe rc=${rc} ($(probe_rc_desc "$rc")), ${prog_out}"
      if [[ "$rc" -eq 0 ]]; then
        log "HEALED check=${dep_check} dep=${c}: connect+progress OK after restart (pre: ${pre_reason}; post: ${post_result})"
        send_alert "$dep_check" "AUTOHEALED" \
          "${c} on $(hostname) had stale Postgres ${host}:${port} connectivity or worker-progress state (cf. t1205u/t1218u).
Auto-restarted the container; TCP connectivity and running-worker progress verified OK after restart.

Pre-restart reason: ${pre_reason}
Post-restart result: ${post_result}

SES/SQS impact window: <1 min (watchdog cadence 1 min)."
      else
        log "STILLFAIL check=${dep_check} dep=${c}: rc=${rc} after restart (pre: ${pre_reason}; post: ${post_result})"
        send_alert "$dep_check" "FAIL" \
          "${c} on $(hostname) failed Postgres ${host}:${port} connectivity or worker-progress check and STILL fails after an auto-restart.

Pre-restart reason: ${pre_reason}
Post-restart result: ${post_result}

PG '${pg}' itself is healthy (pg_isready ok). Check docker network / iptables / app logs."
      fi
    else
      [[ "$?" -eq 2 ]] && continue
      dependent_is_retiring "$c" && continue
      FAILED=1
      send_alert "$dep_check" "FAIL" \
        "${c} on $(hostname) failed Postgres ${host}:${port} connectivity or worker-progress check; restart skipped (cooldown or DRY_RUN).

Pre-restart reason: ${pre_reason}
Post-restart result: not restarted (cooldown or DRY_RUN)

PG '${pg}' itself is healthy (pg_isready ok). If this repeats every cooldown, investigate manually."
    fi
  done

  check_pg_worker_progress "$label" "$pg" "$deps"
}

for label in $PG_LABELS; do
  watch_pg "$label"
done

flush_pending_warns
prune_stale_state_files

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
if [[ "$EXIT_CODE" -ne 0 ]]; then
  log "PG_STANDDOWN"
  exit 2
fi
log "ALL_OK"
exit 0
