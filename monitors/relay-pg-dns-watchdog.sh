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

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-noreply@datatalks.club}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"

command -v docker >/dev/null 2>&1 || { log "FATAL: docker not found"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "FATAL: missing required binary: flock"; exit 1; }

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another watchdog run in progress (lock: $LOCK_FILE); skipping"; exit 0; }

NOW="$(date +%s)"
FAILED=0
EXIT_CODE=0

safe_name() { printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_' | cut -c1-80; }

send_alert() {
  # $1=check-name $2=subject-suffix $3=body  (same dedupe as coolify-healthcheck)
  local name="$1" subject="$2" body="$3"
  local state_file="${STATE_DIR}/${name}.state"
  local last_alert=0 last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"
  fi
  local is_recovery=0
  [[ "$subject" == RECOVERED* || "$subject" == AUTOHEALED* ]] && is_recovery=1
  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    local elapsed_min=$(( (NOW - last_alert) / 60 ))
    if [[ "$elapsed_min" -lt "$ALERT_REPEAT_MIN" ]]; then
      return 0  # still failing, recently alerted — dedupe
    fi
  fi
  local full_subject="[relay-pg-dns-watchdog] ${subject} (${name})"
  local to_csv="${ALERT_TO// /,}"
  local to_header="${to_csv//,/, }"
  local -a to_args=()
  IFS=',' read -r -a to_args <<< "$to_csv"
  local sent="no"
  if command -v sendmail >/dev/null 2>&1; then
    if {
      echo "From: ${ALERT_FROM}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | sendmail -t 2>/dev/null; then sent="sendmail"; fi
  elif command -v msmtp >/dev/null 2>&1; then
    if {
      echo "From: ${ALERT_FROM}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | msmtp -- "${to_args[@]}" 2>/dev/null; then sent="msmtp"; fi
  else
    log "WARN: no MTA (sendmail/msmtp) — alert for ${name} logged only"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${ALERT_TO}"
  printf 'STATUS=%s\nLAST_ALERT=%s\n' \
    "$([ "$is_recovery" -eq 1 ] && echo OK || echo FAIL)" \
    "$([ "$is_recovery" -eq 1 ] && echo 0 || echo "$NOW")" > "$state_file"
}

mark_ok() {
  # $1=check-name — transitions FAIL→RECOVERED notice; silent otherwise
  local name="$1"
  local state_file="${STATE_DIR}/${name}.state"
  local last_status=""
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"
  fi
  if [[ "$last_status" == "FAIL" ]]; then
    send_alert "$name" "RECOVERED" "Check '${name}' green again at $(date -u '+%Y-%m-%dT%H:%M:%SZ')."
  else
    printf 'STATUS=OK\nLAST_ALERT=%s\n' "${LAST_ALERT:-0}" > "$state_file"
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

probe_worker_progress() {
  # $1=dep_container $2=target_pg_container $3=port
  # Verifies running-worker health beyond fresh sibling TCP (t1218u):
  #   a) active :5432 TCP sockets in /proc/1/net/tcp{,6} match live PG IPs
  #   b) background workers do not pre-date a PG container recreate
  #   c) ses-ingress latest batch did not fail 100% (deleted=0 failed>0)
  #   d) background workers have no uncaught DB OperationalError/InterfaceError
  #      after their latest startup banner
  # Echoes summary string; returns 0 if healthy, 4 if stale/stuck.
  [[ "$PROGRESS_CHECKS" == "1" ]] || { printf 'progress=disabled'; return 0; }
  local c="$1" target_pg="$2" port="$3"
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

  if [[ -n "$dep_iso" && "$dep_iso" != "0001-01-01"* ]]; then
    logs="$(docker logs --since "$dep_iso" --tail 200 "$c" 2>&1 || true)"
  else
    logs="$(docker logs --tail 200 "$c" 2>&1 || true)"
  fi

  if [[ "$c" == ses-ingress* ]]; then
    last_batch="$(printf '%s\n' "$logs" | grep -oE 'received=[0-9]+ deleted=[0-9]+ failed=[0-9]+' | tail -n 1 || true)"
    if [[ -n "$last_batch" ]]; then
      if [[ "$last_batch" =~ deleted=0[[:space:]]+failed=[1-9] ]]; then
        printf 'progress=FAIL(ses_ingress_batch_failed:%s)' "${last_batch// /,}"
        return 4
      fi
      printf 'progress=ok(%s,ses_last=%s)' "$peer_out" "${last_batch// /,}"
      return 0
    fi
  fi

  local tail_after_start="$logs"
  if printf '%s\n' "$logs" | grep -qE 'Starting (worker|.*ingress drain|recipient-list import worker|.*callback dispatcher)'; then
    tail_after_start="$(printf '%s\n' "$logs" | awk '
      /Starting (worker|.*ingress drain|recipient-list import worker|.*callback dispatcher)/ { buf=""; next }
      { buf = buf $0 "\n" }
      END { printf "%s", buf }
    ')"
  fi
  if printf '%s\n' "$tail_after_start" | grep -qE '(psycopg2|django\.db\.utils)\.(OperationalError|InterfaceError)'; then
    local err_line
    err_line="$(printf '%s\n' "$tail_after_start" | grep -E '(psycopg2|django\.db\.utils)\.(OperationalError|InterfaceError)' | tail -n 1 | tr -s '[:space:]' '_' | cut -c1-80)"
    printf 'progress=FAIL(worker_db_error_since_start:%s)' "$err_line"
    return 4
  fi

  printf 'progress=ok(%s,logs=clean)' "$peer_out"
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
    local sched_c="" d hb_age hb_check="progress-scheduler-heartbeat"
    for d in $deps; do
      [[ "$d" == scheduler-* ]] && { sched_c="$d"; break; }
    done
    hb_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MAX(ticked_at)))::int, 999999) FROM relay_scheduler_heartbeat;" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$hb_age" =~ ^-?[0-9]+$ ]]; then
      (( hb_age < 0 )) && hb_age=0
      if (( hb_age <= SCHEDULER_MAX_AGE_SEC )); then
        log "OK check=${hb_check} pg=${label} scheduler=${sched_c:-none} age=${hb_age}s max=${SCHEDULER_MAX_AGE_SEC}s"
        mark_ok "$hb_check"
      else
        FAILED=1
        log "FAIL check=${hb_check} pg=${label} scheduler=${sched_c:-none} age=${hb_age}s max=${SCHEDULER_MAX_AGE_SEC}s"
        if [[ -n "$sched_c" ]] && restart_dependent "$sched_c"; then
          sleep "$RESTART_VERIFY_WAIT"
          hb_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MAX(ticked_at)))::int, 999999) FROM relay_scheduler_heartbeat;" 2>/dev/null | tr -d '[:space:]')"
          if [[ "$hb_age" =~ ^-?[0-9]+$ ]] && (( hb_age <= SCHEDULER_MAX_AGE_SEC )); then
            log "HEALED check=${hb_check} scheduler=${sched_c} age=${hb_age}s after restart"
            send_alert "$hb_check" "AUTOHEALED" \
              "Relay scheduler heartbeat (relay_scheduler_heartbeat.ticked_at) on $(hostname) was stale (> ${SCHEDULER_MAX_AGE_SEC}s) while fresh TCP probe was green.
Auto-restarted ${sched_c}; heartbeat age is now ${hb_age}s."
          else
            log "STILLFAIL check=${hb_check} scheduler=${sched_c} age=${hb_age:-unknown}s after restart"
            send_alert "$hb_check" "FAIL" \
              "Relay scheduler heartbeat on $(hostname) remains stale (age=${hb_age:-unknown}s > ${SCHEDULER_MAX_AGE_SEC}s) after restarting ${sched_c}."
          fi
        else
          send_alert "$hb_check" "FAIL" \
            "Relay scheduler heartbeat on $(hostname) is stale (age=${hb_age}s > ${SCHEDULER_MAX_AGE_SEC}s); scheduler=${sched_c:-not-found} restart skipped (cooldown or DRY_RUN)."
        fi
      fi
    fi
  fi

  # 2) django_tasks_database_dbtaskresult ready-backlog freshness
  local has_tasks
  has_tasks="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "SELECT to_regclass('public.django_tasks_database_dbtaskresult') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$has_tasks" == "t" ]]; then
    local q_rows last_pe_ok q_check="progress-task-queues" q_failed=0
    q_rows="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "
      SELECT queue_name || '|' || COUNT(*) || '|' || COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(GREATEST(enqueued_at, run_after))))::int, 0)
      FROM django_tasks_database_dbtaskresult
      WHERE status = 'READY' AND run_after <= NOW()
      GROUP BY queue_name;
    " 2>/dev/null || true)"
    last_pe_ok="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "
      SELECT COALESCE(TO_CHAR(MAX(finished_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), 'none')
      FROM django_tasks_database_dbtaskresult
      WHERE status = 'SUCCESSFUL' AND queue_name = 'provider-events';
    " 2>/dev/null | tr -d '[:space:]')"
    local line qname qcnt qage qworker d
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r qname qcnt qage <<< "$line"
      [[ "$qage" =~ ^-?[0-9]+$ ]] || continue
      if (( qage > TASK_QUEUE_MAX_READY_AGE_SEC )); then
        q_failed=1
        FAILED=1
        qworker=""
        for d in $deps; do
          if [[ "$qname" == "provider-events" && "$d" == provider-events-worker-* ]]; then qworker="$d"; break; fi
          if [[ "$qname" == "default" && "$d" == worker-* ]]; then qworker="$d"; break; fi
        done
        log "FAIL check=${q_check} pg=${label} queue=${qname} ready=${qcnt} oldest_ready=${qage}s max=${TASK_QUEUE_MAX_READY_AGE_SEC}s worker=${qworker:-none}"
        if [[ -n "$qworker" ]] && restart_dependent "$qworker"; then
          sleep "$RESTART_VERIFY_WAIT"
          local new_age
          new_age="$(docker exec "$pg" psql -U "$PGUSER" -d "$db" -tAqc "
            SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(GREATEST(enqueued_at, run_after))))::int, 0)
            FROM django_tasks_database_dbtaskresult
            WHERE status = 'READY' AND run_after <= NOW() AND queue_name = '${qname//\'/}';
          " 2>/dev/null | tr -d '[:space:]')"
          if [[ "$new_age" =~ ^-?[0-9]+$ ]] && (( new_age <= TASK_QUEUE_MAX_READY_AGE_SEC )); then
            log "HEALED check=${q_check} queue=${qname} worker=${qworker} oldest_ready=${new_age}s after restart"
            send_alert "$q_check" "AUTOHEALED" \
              "Relay task queue '${qname}' on $(hostname) had ${qcnt} due READY task(s) stuck for ${qage}s (> ${TASK_QUEUE_MAX_READY_AGE_SEC}s) while fresh TCP probe was green.
Auto-restarted ${qworker}; oldest_ready is now ${new_age}s."
          else
            log "STILLFAIL check=${q_check} queue=${qname} worker=${qworker} oldest_ready=${new_age:-unknown}s after restart"
            send_alert "$q_check" "FAIL" \
              "Relay task queue '${qname}' on $(hostname) still has due READY task(s) stuck (oldest_ready=${new_age:-unknown}s > ${TASK_QUEUE_MAX_READY_AGE_SEC}s) after restarting ${qworker}."
          fi
        else
          send_alert "$q_check" "FAIL" \
            "Relay task queue '${qname}' on $(hostname) has ${qcnt} due READY task(s) stuck for ${qage}s (> ${TASK_QUEUE_MAX_READY_AGE_SEC}s); worker=${qworker:-not-found} restart skipped (cooldown or DRY_RUN)."
        fi
      fi
    done <<< "$q_rows"
    if (( q_failed == 0 )); then
      log "OK check=${q_check} pg=${label} stuck_ready=0 max_age=${TASK_QUEUE_MAX_READY_AGE_SEC}s last_provider_event_ok=${last_pe_ok:-none}"
      mark_ok "$q_check"
    fi
  fi
}

restart_dependent() {
  # $1=container — cooldown-gated docker restart; 0 if a restart happened now
  local c="$1" stamp="${STATE_DIR}/restart-$(safe_name "$1").stamp" last=0
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
  if ! docker restart "$c" >/dev/null 2>&1; then
    log "RESTART dep=${c}: docker restart FAILED"
    return 1
  fi
  printf '%s\n' "$NOW" > "$stamp"
  return 0
}

watch_pg() {
  # $1=coolify.resourceName label
  local label="$1" pg pgname deps c dep_nets n nets pg_nets target host port rc
  local dep_check target_pg prog_out
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

  deps=""
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    [[ "$c" == "$pg" ]] && continue
    [[ "$c" =~ $DEPENDENT_EXCLUDE ]] && continue
    dep_nets="$(pg_container_networks "$c")"
    nets=""
    for n in $dep_nets; do
      [[ " $pg_nets " == *" $n "* ]] && nets="$nets $n"
    done
    [[ -z "${nets// /}" ]] && continue
    container_has_env_key "$c" 'DATABASE_URL|POSTGRES_HOST' || continue
    deps="$deps $c"
  done
  if [[ -z "${deps// /}" ]]; then
    log "WARN pg=${label}: no dependent containers found (env-gated: DATABASE_URL/POSTGRES_HOST)"
    return
  fi

  for c in $deps; do
    target="$(parse_db_target "$(dep_env_block "$c")")"
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
    if [[ "$rc" -eq 0 ]]; then
      if prog_out="$(probe_worker_progress "$c" "$target_pg" "$port")"; then
        log "OK check=${dep_check} dep=${c} host=${host}:${port} $(resolved_addrs "$c" "$host") ${prog_out}"
        mark_ok "$dep_check"
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
    FAILED=1
    log "FAIL check=${dep_check} dep=${c} host=${host}:${port} rc=${rc} $(resolved_addrs "$c" "$host") ${prog_out}"
    if [[ "$host" != "$pgname" && "$host" != "$pg" ]] && ! name_known_to_docker "$host" "$pg"; then
      # Stale NAME (PG redeployed under a new uuid) — restart cannot fix.
      send_alert "$dep_check" "FAIL" \
        "${c} on $(hostname) references Postgres name '${host}' which docker DNS no longer resolves.
pg-${label} is now container '${pg}' (name=${pgname}) and is healthy — the app env still points at the old uuid name.
Fix: redeploy the app in Coolify (picks up current DATABASE_URL host) or update its DATABASE_URL/POSTGRES_HOST.
No restart attempted (would not help)."
      continue
    fi
    if restart_dependent "$c"; then
      sleep "$RESTART_VERIFY_WAIT"
      probe_from_container "$c" "$host" "$port" && rc=0 || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        if prog_out="$(probe_worker_progress "$c" "$target_pg" "$port")"; then
          rc=0
        else
          rc=4
        fi
      fi
      if [[ "$rc" -eq 0 ]]; then
        log "HEALED check=${dep_check} dep=${c}: connect+progress OK after restart (${prog_out})"
        send_alert "$dep_check" "AUTOHEALED" \
          "${c} on $(hostname) had stale Postgres ${host}:${port} connectivity or worker-progress state (${prog_out}, cf. t1205u/t1218u).
Auto-restarted the container; TCP connectivity and running-worker progress verified OK after restart.
SES/SQS impact window: <1 min (watchdog cadence 1 min)."
      else
        log "STILLFAIL check=${dep_check} dep=${c}: rc=${rc} after restart (${prog_out})"
        send_alert "$dep_check" "FAIL" \
          "${c} on $(hostname) failed Postgres ${host}:${port} connectivity or worker-progress check and STILL fails after an auto-restart (probe rc=${rc}, ${prog_out}).
PG '${pg}' itself is healthy (pg_isready ok). Check docker network / iptables / app logs."
      fi
    else
      send_alert "$dep_check" "FAIL" \
        "${c} on $(hostname) failed Postgres ${host}:${port} connectivity or worker-progress check (probe rc=${rc}, ${prog_out}); restart skipped (cooldown or DRY_RUN).
PG '${pg}' itself is healthy (pg_isready ok). If this repeats every cooldown, investigate manually."
    fi
  done

  check_pg_worker_progress "$label" "$pg" "$deps"
}

for label in $PG_LABELS; do
  watch_pg "$label"
done

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
