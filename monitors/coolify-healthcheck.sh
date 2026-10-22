#!/usr/bin/env bash
# Permanent continuous healthcheck for Coolify Contabo Postgres + services.
#
# Runs ON the data node (contabo-b) and/or the primary (contabo-a) as a
# frequent cron job (see coolify-healthcheck.cron: every 5 min Europe/Berlin).
# This is the CONTINUOUS check — unlike the daily pg_dump job in backups/,
# this runs every few minutes and alerts on failure.
#
# What it checks:
#   1. Postgres pg-shared: pg_isready + SELECT 1 (docker exec into the
#      Coolify Postgres container, or TCP via PGHOST/PGPORT + password).
#   2. Postgres pg-relay:  same, against the separate Relay instance.
#   3. HTTP/app endpoints:  configurable list (Coolify UI, Relay, CMP, AISHL,
#      website) — curl must return 2xx/3xx within the timeout.
#
# Alerting: on failure, sends email to ALERT_TO (default dev@dtcdev.click)
# via sendmail/msmtp when available. Dedupe/rate-limit: an alert fires once
# per failing check, then repeats at most every ALERT_REPEAT_MIN minutes
# while still failing; a RECOVERED notice goes out on transition back to OK.
# No alert spam for a single ongoing outage.
#
# Secrets: NEVER in git. All credentials/URLs come from an env file
# (/etc/coolify-healthcheck.env, root-only 600). See env.example.
#
# Exit code: 0 if every check passed, 1 if any check failed.
set -euo pipefail

ENV_FILE="${COOLIFY_HEALTHCHECK_ENV_FILE:-/etc/coolify-healthcheck.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---- config (overridable via env file) ----
STATE_DIR="${STATE_DIR:-/var/lib/coolify-healthcheck}"
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-healthcheck.lock}"
LOG_FILE="${LOG_FILE:-/var/log/coolify-healthcheck.log}"

PG_SHARED_CONTAINER="${PG_SHARED_CONTAINER:-}"
# Coolify standalone-postgresql creates only the POSTGRES_USER role (pgadmin) —
# there is NO `postgres` role (2026-10-22 pg-relay alert: FATAL: role "postgres" does not exist).
PGUSER_SHARED="${PGUSER_SHARED:-pgadmin}"
PG_SHARED_DB="${PG_SHARED_DB:-postgres}"   # db used for SELECT 1 on pg-shared
PGHOST_SHARED="${PGHOST_SHARED:-127.0.0.1}"
PGPORT_SHARED="${PGPORT_SHARED:-5433}"
PGPASSWORD_SHARED="${PGPASSWORD_SHARED:-}"

PG_RELAY_CONTAINER="${PG_RELAY_CONTAINER:-}"
PGUSER_RELAY="${PGUSER_RELAY:-pgadmin}"
PG_RELAY_DB="${PG_RELAY_DB:-relay}"        # db used for SELECT 1 on pg-relay (NOT postgres)
PGHOST_RELAY="${PGHOST_RELAY:-127.0.0.1}"
PGPORT_RELAY="${PGPORT_RELAY:-5434}"
PGPASSWORD_RELAY="${PGPASSWORD_RELAY:-}"

# Coolify gives Postgres containers random uuid names (e.g. mqimefrti7ratmaliirnikov)
# that change on redeploy. When PG_*_CONTAINER is empty, resolve via the stable
# Coolify label (coolify.resourceName=pg-shared|pg-relay) on the local docker.
resolve_pg_container() {
  # $1=current value $2=coolify.resourceName
  local cur="$1" label="$2" found=""
  if [[ -z "$cur" ]] && command -v docker >/dev/null 2>&1; then
    found="$(docker ps --filter "label=coolify.resourceName=${label}" --format '{{.Names}}' 2>/dev/null | head -n 1)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  fi
  echo "$cur"
}
PG_SHARED_CONTAINER="$(resolve_pg_container "$PG_SHARED_CONTAINER" "pg-shared")"
PG_RELAY_CONTAINER="$(resolve_pg_container "$PG_RELAY_CONTAINER" "pg-relay")"

# Space-separated name=url pairs, e.g.:
#   APP_URLS="coolify_ui=http://169.58.119.163:8000/ relay=https://relay.example.com/healthz"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"

ALERT_TO="${ALERT_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-noreply@datatalks.club}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"

command -v curl >/dev/null 2>&1 || { log "ERROR: missing required binary: curl"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "ERROR: missing required binary: flock"; exit 1; }

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "WARN: another healthcheck run is in progress (lock: $LOCK_FILE); skipping"; exit 0; }

FAILED=0
NOW="$(date +%s)"

send_alert() {
  # $1=check-name $2=subject-suffix $3=body
  local name="$1" subject="$2" body="$3"
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
      return 0  # still failing, recently alerted — dedupe
    fi
  fi
  local full_subject="[coolify-healthcheck] ${subject} (${name})"
  local sent="no"
  # ALERT_TO may be comma-separated; prod default is only dev@dtcdev.click
  local to_csv="${ALERT_TO// /,}"
  local to_header="${to_csv//,/, }"
  local -a to_args=()
  IFS=',' read -r -a to_args <<< "$to_csv"
  if command -v sendmail >/dev/null 2>&1; then
    if {
      echo "From: ${ALERT_FROM}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | sendmail -t 2>/dev/null; then
      sent="sendmail"
    else
      log "WARN: sendmail failed for ${name}"
    fi
  elif command -v msmtp >/dev/null 2>&1; then
    if {
      echo "From: ${ALERT_FROM}"
      echo "To: ${to_header}"
      echo "Subject: ${full_subject}"
      echo ""
      printf '%s\n' "$body"
    } | msmtp -- "${to_args[@]}" 2>/dev/null; then
      sent="msmtp"
    else
      log "WARN: msmtp failed for ${name}"
    fi
  else
    log "WARN: no MTA (sendmail/msmtp) on this host — alert for ${name} logged only; install msmtp and configure SMTP (see README)"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${ALERT_TO}"
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

check_postgres() {
  # $1=stack $2=container $3=user $4=db $5=host $6=port $7=password
  local stack="$1" container="$2" user="$3" db="$4" host="$5" port="$6" password="$7"
  local name="pg-${stack}" out rc
  if [[ -n "$container" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      log "FAIL check=${name}: docker not found but PG container configured"
      send_alert "$name" "FAIL" "docker binary missing on $(hostname); cannot pg_isready container ${container}."
      FAILED=1; return
    fi
    out="$(docker exec "$container" pg_isready -U "$user" -d "$db" 2>&1)" && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "FAIL check=${name}: pg_isready via ${container}: ${out}"
      send_alert "$name" "FAIL" "pg_isready failed for ${stack} via container ${container}: ${out}"
      FAILED=1; return
    fi
    out="$(docker exec "$container" psql -U "$user" -d "$db" -tAc 'SELECT 1' 2>&1)" && rc=0 || rc=$?
    if [[ "$rc" -ne 0 || "$(echo "$out" | tr -d '[:space:]')" != "1" ]]; then
      log "FAIL check=${name}: SELECT 1 via ${container}: rc=${rc} out='${out}'"
      if [[ "$out" == *'role "'*'" does not exist'* ]]; then
        log "HINT check=${name}: Coolify Postgres has no 'postgres' role — set PGUSER_${stack^^} to the Coolify POSTGRES_USER (usually pgadmin) in ${ENV_FILE}"
      fi
      send_alert "$name" "FAIL" "SELECT 1 failed for ${stack} via container ${container} (rc=${rc}): ${out}"
      FAILED=1; return
    fi
  else
    if ! command -v pg_isready >/dev/null 2>&1; then
      log "FAIL check=${name}: pg_isready not found and no container configured (need postgresql-client)"
      send_alert "$name" "FAIL" "pg_isready missing on $(hostname) and no ${stack} container configured; cannot check TCP ${host}:${port}."
      FAILED=1; return
    fi
    out="$(PGPASSWORD="$password" pg_isready -h "$host" -p "$port" -d "$db" 2>&1)" && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "FAIL check=${name}: pg_isready ${host}:${port}: ${out}"
      send_alert "$name" "FAIL" "pg_isready failed for ${stack} at ${host}:${port}: ${out}"
      FAILED=1; return
    fi
    if ! command -v psql >/dev/null 2>&1; then
      log "OK check=${name}: pg_isready ${host}:${port} ok (psql absent, SELECT 1 skipped)"
      mark_ok "$name"; return
    fi
    out="$(PGPASSWORD="$password" PGHOST="$host" PGPORT="$port" PGUSER="$user" psql -d "$db" -tAc 'SELECT 1' 2>&1)" && rc=0 || rc=$?
    if [[ "$rc" -ne 0 || "$(echo "$out" | tr -d '[:space:]')" != "1" ]]; then
      log "FAIL check=${name}: SELECT 1 ${host}:${port}/${db}: rc=${rc} out='${out}'"
      if [[ "$out" == *'role "'*'" does not exist'* ]]; then
        log "HINT check=${name}: Coolify Postgres has no 'postgres' role — set PGUSER_${stack^^} to the Coolify POSTGRES_USER (usually pgadmin) in ${ENV_FILE}"
      fi
      send_alert "$name" "FAIL" "SELECT 1 failed for ${stack} at ${host}:${port}/${db} (rc=${rc}): ${out}"
      FAILED=1; return
    fi
  fi
  log "OK check=${name}"
  mark_ok "$name"
}

check_http() {
  # $1=name $2=url
  local name="http-${1}" url="$2" code rc
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time "$HTTP_TIMEOUT" "$url" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log "FAIL check=${name}: curl ${url}: ${code}"
    send_alert "$name" "FAIL" "HTTP check failed for '${1}' (${url}): ${code}"
    FAILED=1; return
  fi
  if [[ ! "$code" =~ ^[23] ]]; then
    log "FAIL check=${name}: ${url} returned HTTP ${code}"
    send_alert "$name" "FAIL" "HTTP check for '${1}' (${url}) returned status ${code} (want 2xx/3xx)."
    FAILED=1; return
  fi
  log "OK check=${name}: ${url} -> ${code}"
  mark_ok "$name"
}

# ---- run ----
# Set SKIP_PG_SHARED=1 / SKIP_PG_RELAY=1 on hosts that cannot reach Postgres
# (e.g. contabo-a when PG is docker-only on contabo-b).
if [[ "${SKIP_PG_SHARED:-0}" == "1" ]]; then
  log "SKIP check=pg-shared (SKIP_PG_SHARED=1)"
else
  check_postgres "shared" "$PG_SHARED_CONTAINER" "$PGUSER_SHARED" "$PG_SHARED_DB" \
    "$PGHOST_SHARED" "$PGPORT_SHARED" "$PGPASSWORD_SHARED"
fi

if [[ "${SKIP_PG_RELAY:-0}" == "1" ]]; then
  log "SKIP check=pg-relay (SKIP_PG_RELAY=1)"
else
  check_postgres "relay" "$PG_RELAY_CONTAINER" "$PGUSER_RELAY" "$PG_RELAY_DB" \
    "$PGHOST_RELAY" "$PGPORT_RELAY" "$PGPASSWORD_RELAY"
fi

if [[ -n "${APP_URLS:-}" ]]; then
  # shellcheck disable=SC2086
  for pair in $APP_URLS; do
    app="${pair%%=*}"; url="${pair#*=}"
    [[ -n "$app" && -n "$url" && "$url" != "$pair" ]] || { log "WARN: skipping malformed APP_URLS entry: ${pair}"; continue; }
    check_http "$app" "$url"
  done
else
  log "WARN: APP_URLS is empty — no HTTP checks configured (fill /etc/coolify-healthcheck.env)"
fi

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
