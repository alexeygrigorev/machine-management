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
#   4. From INSIDE each dependent, resolves + TCP-connects to the DB host
#      exactly like the app would (python3 socket first, bash /dev/tcp
#      fallback).
#   5. On failure of a healthy-Postgres-dependent:
#        - referenced name no longer known to docker DNS and != current PG
#          name -> STALE-NAME (PG redeployed): restart can NOT fix -> alert
#          with the fix (redeploy app / update env). No restart.
#        - else -> `docker restart <dep>` (per-container cooldown gated),
#          re-probe; alert AUTOHEALED or STILL-FAILING (deduped).
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

pg_container_networks() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null
}

pg_selfcheck_ok() {
  # $1=pg container — 0 (ok) only if running + (health green if defined) + pg_isready
  local pg="$1" state health out rc
  state="$(docker inspect -f '{{.State.Running}}' "$pg" 2>/dev/null || echo missing)"
  [[ "$state" == "true" ]] || return 1
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$pg" 2>/dev/null || echo none)"
  [[ "$health" == "none" || "$health" == "healthy" ]] || return 1
  out="$(docker exec "$pg" pg_isready -U "$PGUSER" -d "$PG_DB" 2>&1)" && rc=0 || rc=$?
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
  log "RESTART dep=${c}: restarting (stale DNS/conn state remedy, t1205u)"
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
  local dep_check
  pg="$(resolve_pg_container "$label")"
  if [[ -z "$pg" ]]; then
    log "FAIL pg=${label}: no container with label coolify.resourceName=${label}"
    send_alert "pg-${label}" "FAIL" \
      "No running container with label coolify.resourceName=${label} on $(hostname). Postgres gone? Watchdog cannot protect dependents."
    FAILED=1
    return
  fi
  pgname="$(docker inspect -f '{{.Name}}' "$pg" 2>/dev/null | sed 's#^/##')"
  if ! pg_selfcheck_ok "$pg"; then
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
    probe_from_container "$c" "$host" "$port"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
      log "OK check=${dep_check} dep=${c} host=${host}:${port} $(resolved_addrs "$c" "$host")"
      mark_ok "$dep_check"
      continue
    fi
    if [[ "$rc" -eq 3 ]]; then
      continue  # no tooling in image — logged, no false page
    fi
    FAILED=1
    log "FAIL check=${dep_check} dep=${c} host=${host}:${port} rc=${rc} $(resolved_addrs "$c" "$host")"
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
        log "HEALED check=${dep_check} dep=${c}: connect OK after restart"
        send_alert "$dep_check" "AUTOHEALED" \
          "${c} on $(hostname) could not reach Postgres ${host}:${port} (stale DNS/conn state, cf. t1205u).
Auto-restarted the container; connectivity verified OK after restart.
SES/SQS impact window: <1 min (watchdog cadence 1 min)."
      else
        log "STILLFAIL check=${dep_check} dep=${c}: rc=${rc} after restart"
        send_alert "$dep_check" "FAIL" \
          "${c} on $(hostname) could not reach Postgres ${host}:${port} and STILL fails after an auto-restart (probe rc=${rc}).
PG '${pg}' itself is healthy (pg_isready ok). Check docker network / iptables / app logs."
      fi
    else
      send_alert "$dep_check" "FAIL" \
        "${c} on $(hostname) cannot reach Postgres ${host}:${port} (probe rc=${rc}); restart skipped (cooldown or DRY_RUN).
PG '${pg}' itself is healthy (pg_isready ok). If this repeats every cooldown, investigate manually."
    fi
  done
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
