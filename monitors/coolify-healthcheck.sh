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
#   4. Content markers (CONTENT_CHECKS): 2xx/3xx plus a verbatim body marker.
#   5. AISHL django_q (CHECK_AISL_Q=1, data host only): recurring task
#      failures + worker progress. Dumps/WAL freshness, disk, and residual
#      Created-container detection.
#
# Alerting: on failure, sends email to ALERT_TO (default alexey@datatalks.club,dev@dtcdev.click)
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

# --- backup freshness / disk (t1146u–t1153u; Contabo .dump.gz path, not parquet) ---
DUMP_DIR="${DUMP_DIR:-/var/backups/coolify-postgres}"
EXPECT_DBS="${EXPECT_DBS:-cmp aisl website relay}"
# Nightly dump at 02:30 Berlin → stale if newest artifact older than ~36h
DUMP_STALE_SECONDS="${DUMP_STALE_SECONDS:-129600}"
WAL_STATE_DIR="${WAL_SHIPPER_STATE_DIR:-/var/lib/coolify-wal-shipper}"
WAL_STACKS="${WAL_STACKS:-pg-shared}"
# archive_timeout=300 + shipper */1min → alert if last success > 20 min
WAL_STALE_SECONDS="${WAL_STALE_SECONDS:-1200}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"
SKIP_BACKUP_CHECKS="${SKIP_BACKUP_CHECKS:-0}"
SKIP_DISK_CHECK="${SKIP_DISK_CHECK:-0}"

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
# NOTE: these are STATUS-ONLY checks (2xx/3xx). They catch TCP/DNS outages
# but NOT wrong-content incidents (proxy default page, error page with 200).
# Pair every user-facing surface with a CONTENT_CHECKS entry below.
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
# Connect phase includes DNS. Contabo systemd-resolved occasionally stalls >5s
# (t1228u: FAIL http-relay "Resolving timed out after 5001 milliseconds" then
# RECOVERED next cron). Retry transient curl 28 / resolve-timeout only — never
# soft-pass real HTTP 4xx/5xx.
HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-10}"
HTTP_RETRIES="${HTTP_RETRIES:-2}"
HTTP_RETRY_SLEEP_SEC="${HTTP_RETRY_SLEEP_SEC:-1}"

# Space-separated name=url::marker triples for CONTENT-marker checks.
# The URL must return 2xx/3xx AND its body must contain the marker.
# Matching: body is lowercased + all whitespace stripped, then fixed-string
# (grep -F) matched — so write markers LOWERCASE with NO whitespace.
# Split is on the FIRST '=' (name|rest) then the FIRST '::' (url|marker):
# names/URLs must not contain '::' (no IPv6 literals), markers must not
# contain spaces or '::'. Example:
#   CONTENT_CHECKS="courses_api=https://courses.datatalks.club/api/health/::\"status\":\"ok\""
CONTENT_CHECKS="${CONTENT_CHECKS:-}"

ALERT_TO="${ALERT_TO:-alexey@datatalks.club,dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-noreply@datatalks.club}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"
# Suppress RECOVERED mail when the FAIL lasted shorter than this many seconds
# (t1273u/t1274u: cut rapid FAIL→RECOVERED pair spam for one-tick flakes).
# FAIL itself still pages immediately — do NOT raise FAIL_STREAK for prod HTTP
# (AISHL Coolify replace 503 must remain visible until zero-downtime is fixed).
RECOVER_NOTIFY_MIN_SEC="${RECOVER_NOTIFY_MIN_SEC:-600}"
# When 1, skip APP_URLS + CONTENT_CHECKS that hit public hostnames (dedupe:
# only one Contabo node should page for the same public URL). Keep local
# checks (127.0.0.1 / 10.100.0.x). Set on contabo-a; leave 0 on contabo-b.
SKIP_PUBLIC_HTTP_CHECKS="${SKIP_PUBLIC_HTTP_CHECKS:-0}"

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
    FAIL_SINCE="${FAIL_SINCE:-0}"
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
  # ALERT_TO may be comma-separated; prod default alexey@datatalks.club,dev@dtcdev.click (t1205u)
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

is_public_url() {
  # $1=url — true (return 0) when the URL host is not loopback/WG-private.
  local url="$1" host
  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | sed -E 's#[:/].*##')"
  case "$host" in
    127.0.0.1|localhost|::1) return 1 ;;
    10.100.0.*|10.0.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
    *) return 0 ;;
  esac
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


# Curl with bounded retries for transient DNS/connect timeouts (curl rc 28).
# Prints http_code on stdout when successful; on final failure prints curl stderr
# (and possibly a trailing http_code of 000) and returns curl's rc.
curl_http_code() {
  # $1=url  $2=extra curl args for body sink, e.g. empty or "-o /tmp/x"
  # Uses global HTTP_* knobs. Echoes code to stdout; returns curl rc.
  local url="$1"; shift
  local attempt=1 max=$((HTTP_RETRIES + 1)) code rc err
  while true; do
    err="$(mktemp)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$@" "$url" 2>"$err")" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$err"
      printf '%s\n' "$code"
      return 0
    fi
    # Transient: resolve/connect timeout (28). Retry up to HTTP_RETRIES times.
    if [[ "$rc" -eq 28 && "$attempt" -lt "$max" ]]; then
      log "WARN check=http-retry: attempt=${attempt}/${max} url=${url} rc=28 detail=$(tr -d '\n' <"$err"); sleeping ${HTTP_RETRY_SLEEP_SEC}s" >&2
      rm -f "$err"
      sleep "$HTTP_RETRY_SLEEP_SEC"
      attempt=$((attempt + 1))
      continue
    fi
    # Final failure: surface curl stderr + code (often 000)
    if [[ -s "$err" ]]; then
      printf '%s %s\n' "$(tr -d '\n' <"$err")" "${code:-000}"
    else
      printf '%s\n' "${code:-000}"
    fi
    rm -f "$err"
    return "$rc"
  done
}

check_http() {
  # $1=name $2=url
  local name="http-${1}" url="$2" code rc
  code="$(curl_http_code "$url")" && rc=0 || rc=$?
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

check_content() {
  # $1=name $2=url $3=marker (lowercase, no whitespace — see CONTENT_CHECKS)
  local name="content-${1}" url="$2" marker="$3" code rc body_file
  body_file="$(mktemp)" || { log "FAIL check=${name}: mktemp failed"; FAILED=1; return; }
  # Same transient DNS retry as check_http (t1228u).
  local attempt=1 max=$((HTTP_RETRIES + 1)) err
  while true; do
    err="$(mktemp)"
    code="$(curl -sS -o "$body_file" -w '%{http_code}' --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$url" 2>"$err")" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$err"
      break
    fi
    if [[ "$rc" -eq 28 && "$attempt" -lt "$max" ]]; then
      log "WARN check=content-retry: attempt=${attempt}/${max} url=${url} rc=28 detail=$(tr -d '
' <"$err"); sleeping ${HTTP_RETRY_SLEEP_SEC}s"
      rm -f "$err"
      sleep "$HTTP_RETRY_SLEEP_SEC"
      attempt=$((attempt + 1))
      continue
    fi
    detail="$(tr -d '
' <"$err") ${code:-000}"
    rm -f "$err"
    log "FAIL check=${name}: curl ${url}: rc=${rc} detail='${detail}'"
    send_alert "$name" "FAIL" "Content check failed for '${1}' (${url}): curl rc=${rc}: ${detail}"
    FAILED=1; rm -f "$body_file"; return
  done
  if [[ ! "$code" =~ ^[23] ]]; then
    log "FAIL check=${name}: ${url} returned HTTP ${code} (want 2xx/3xx; marker not evaluated)"
    send_alert "$name" "FAIL" "Content check for '${1}' (${url}) returned status ${code}; marker '${marker}' not evaluated."
    FAILED=1; rm -f "$body_file"; return
  fi
  if tr '[:upper:]' '[:lower:]' < "$body_file" | tr -d '[:space:]' | grep -Fq -- "$marker"; then
    log "OK check=${name}: ${url} -> ${code} marker='${marker}'"
    mark_ok "$name"
  else
    log "FAIL check=${name}: ${url} -> ${code} but marker '${marker}' absent"
    send_alert "$name" "FAIL" "Content check for '${1}' (${url}) returned HTTP ${code} but the body lacks marker '${marker}' — the app may be serving wrong content (proxy default page, error page with 200, or empty body)."
    FAILED=1
  fi
  rm -f "$body_file"
}


check_disk() {
  local name="disk-root" used_pct
  used_pct="$(df -BP / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  if [[ -z "$used_pct" || ! "$used_pct" =~ ^[0-9]+$ ]]; then
    log "FAIL check=${name}: could not parse df"
    send_alert "$name" "FAIL" "Unable to parse root filesystem usage on $(hostname)."
    FAILED=1; return
  fi
  if [[ "$used_pct" -ge "$DISK_WARN_PERCENT" ]]; then
    log "FAIL check=${name}: / at ${used_pct}% (threshold ${DISK_WARN_PERCENT}%)"
    send_alert "$name" "FAIL" "Root filesystem on $(hostname) is ${used_pct}% full (threshold ${DISK_WARN_PERCENT}%). Contabo-b dumps/WAL must stay off-host; free space or prune."
    FAILED=1; return
  fi
  log "OK check=${name}: / at ${used_pct}% (<${DISK_WARN_PERCENT}%)"
  mark_ok "$name"
}

check_dump_freshness() {
  local db f mtime age name
  local now; now="$(date +%s)"
  for db in $EXPECT_DBS; do
    name="dump-${db}"
    f="$(ls -1t "$DUMP_DIR"/${db}-*.dump.gz 2>/dev/null | head -1 || true)"
    if [[ -z "$f" || ! -f "$f" ]]; then
      log "FAIL check=${name}: no local .dump.gz under ${DUMP_DIR}"
      send_alert "$name" "FAIL" "No nightly pg_dump artifact for db=${db} under ${DUMP_DIR} on $(hostname). Contabo path is .dump.gz→S3 (not parquet)."
      FAILED=1; continue
    fi
    mtime="$(stat -c%Y "$f")"
    age=$(( now - mtime ))
    if [[ "$age" -gt "$DUMP_STALE_SECONDS" ]]; then
      log "FAIL check=${name}: age=${age}s > ${DUMP_STALE_SECONDS}s file=$(basename "$f")"
      send_alert "$name" "FAIL" "Dump for db=${db} is stale: $(basename "$f") age ${age}s (threshold ${DUMP_STALE_SECONDS}s) size=$(stat -c%s "$f")B on $(hostname)."
      FAILED=1; continue
    fi
    log "OK check=${name}: $(basename "$f") age=${age}s size=$(stat -c%s "$f")B"
    mark_ok "$name"
  done
}

check_wal_freshness() {
  local stack sf ts_raw ts age name
  local now; now="$(date +%s)"
  for stack in $WAL_STACKS; do
    name="wal-${stack}"
    sf="${WAL_STATE_DIR}/last-success-${stack}"
    if [[ ! -f "$sf" ]]; then
      log "FAIL check=${name}: missing ${sf}"
      send_alert "$name" "FAIL" "WAL shipper last-success missing for stack=${stack} (${sf}) on $(hostname)."
      FAILED=1; continue
    fi
    ts_raw="$(tr -d '[:space:]' < "$sf")"
    ts="$(date -u -d "$ts_raw" +%s 2>/dev/null || echo 0)"
    if [[ "$ts" -le 0 ]]; then
      log "FAIL check=${name}: unparseable timestamp '${ts_raw}'"
      send_alert "$name" "FAIL" "WAL shipper last-success unparseable for stack=${stack}: '${ts_raw}'"
      FAILED=1; continue
    fi
    age=$(( now - ts ))
    if [[ "$age" -gt "$WAL_STALE_SECONDS" ]]; then
      log "FAIL check=${name}: age=${age}s > ${WAL_STALE_SECONDS}s last=${ts_raw}"
      send_alert "$name" "FAIL" "WAL archive stale for stack=${stack}: last success ${ts_raw} (age ${age}s, threshold ${WAL_STALE_SECONDS}s) on $(hostname)."
      FAILED=1; continue
    fi
    log "OK check=${name}: last=${ts_raw} age=${age}s"
    mark_ok "$name"
  done
}

# Callback delivery can fail while HTTP and Postgres health remain green.
# Enable on the Relay data host; use the existing label discovery / TCP config.
check_cmp_callbacks() {
  local name="cmp-callbacks" out rc pending recent sql
  sql="SELECT count(*) FILTER (WHERE status='pending' AND created_at < now() - interval '30 minutes'), count(*) FILTER (WHERE status='failed' AND last_attempt_at >= now() - interval '24 hours') FROM cmp_callbacks WHERE status IN ('pending','failed')"
  if [[ -n "$PG_RELAY_CONTAINER" ]]; then
    out="$(timeout 20 docker exec -e PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' "$PG_RELAY_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$PGUSER_RELAY" -d "$PG_RELAY_DB" -tAc "$sql" 2>/dev/null)" && rc=0 || rc=$?
  else
    out="$(PGPASSWORD="$PGPASSWORD_RELAY" PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' timeout 20 psql -X -v ON_ERROR_STOP=1 -h "$PGHOST_RELAY" -p "$PGPORT_RELAY" -U "$PGUSER_RELAY" -d "$PG_RELAY_DB" -tAc "$sql" 2>/dev/null)" && rc=0 || rc=$?
  fi
  if [[ "$rc" -ne 0 || ! "$out" =~ ^[0-9]+\|[0-9]+$ ]]; then
    log "FAIL check=${name}: callback count query failed or returned invalid counts (rc=${rc})"
    send_alert "$name" "FAIL" "Cannot verify Relay callback delivery: count query failed or returned invalid counts (rc=${rc})."
    FAILED=1; return
  fi
  IFS='|' read -r pending recent <<< "$out"
  if [[ "$pending" -gt 0 || "$recent" -gt 0 ]]; then
    log "FAIL check=${name}: pending_older_30m=${pending} failed_last_24h=${recent}"
    send_alert "$name" "FAIL" "Relay to CMP delivery stalled: pending_older_30m=${pending} failed_last_24h=${recent}. Check CMP webhook configuration and Relay callback worker."
    FAILED=1; return
  fi
  log "OK check=${name}: pending_older_30m=0 failed_last_24h=0"
  mark_ok "$name"
}

# AISHL django_q failure + worker progress (t1143u: the
# content.tasks.peer_reviews.form_self_paced_review_batches query fails
# roughly every 15m; the sibling AISHL worker owns the SQL fix — this check
# only pages while failures recur, and auto-recovers when fixed).
# Enable ONLY on the host with the local pg-shared container (contabo-b):
#   CHECK_AISL_Q=1
# Read-only SQL (statement_timeout + default_transaction_read_only), same
# pattern as check_cmp_callbacks; no passwords in git (node env only).
check_aisl_q() {
  local name="aisl-q" out rc fail24 prog_age now
  AISL_Q_FAIL_MAX_24H="${AISL_Q_FAIL_MAX_24H:-10}"
  AISL_Q_PROGRESS_MAX_AGE_SEC="${AISL_Q_PROGRESS_MAX_AGE_SEC:-3600}"
  if [[ -z "$PG_SHARED_CONTAINER" ]]; then
    log "FAIL check=${name}: CHECK_AISL_Q=1 but no local pg-shared container (enable only on contabo-b)"
    send_alert "$name" "FAIL" "CHECK_AISL_Q=1 on $(hostname) but no local pg-shared container resolved — move this flag to the PG data host."
    FAILED=1; return
  fi
  if ! command -v docker >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    log "FAIL check=${name}: need docker + timeout binaries"
    send_alert "$name" "FAIL" "docker/timeout missing on $(hostname); cannot probe aisl django_q."
    FAILED=1; return
  fi
  out="$(timeout 20 docker exec -e PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' "$PG_SHARED_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$PGUSER_SHARED" -d aisl -tAc "SELECT count(*) FROM django_q_task WHERE success=false AND stopped > now() - interval '24 hours';" 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
    log "FAIL check=${name}: django_q failure-count query failed (rc=${rc})"
    send_alert "$name" "FAIL" "Cannot verify AISHL task failures: django_q_task count query failed (rc=${rc})."
    FAILED=1; return
  fi
  fail24="$(echo "$out" | tr -d '[:space:]')"
  out="$(timeout 20 docker exec -e PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' "$PG_SHARED_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$PGUSER_SHARED" -d aisl -tAc "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - max(stopped)))::int, -1) FROM django_q_task WHERE success=true;" 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 || ! "$out" =~ ^-?[0-9]+$ ]]; then
    log "FAIL check=${name}: django_q progress query failed (rc=${rc})"
    send_alert "$name" "FAIL" "Cannot verify AISHL worker progress: django_q_task progress query failed (rc=${rc})."
    FAILED=1; return
  fi
  prog_age="$(echo "$out" | tr -d '[:space:]')"
  if [[ "$fail24" -gt "$AISL_Q_FAIL_MAX_24H" ]]; then
    log "FAIL check=${name}: failed_last_24h=${fail24} (> ${AISL_Q_FAIL_MAX_24H}) success_age=${prog_age}s"
    send_alert "$name" "FAIL" "AISHL django_q_task failures recurring: failed_last_24h=${fail24} (threshold ${AISL_Q_FAIL_MAX_24H}). Known suspect: content.tasks.peer_reviews.form_self_paced_review_batches (FOR UPDATE on outer-join nullable side) — owned by the AISHL app worker, not monitoring."
    FAILED=1; return
  fi
  if [[ "$prog_age" -lt 0 || "$prog_age" -gt "$AISL_Q_PROGRESS_MAX_AGE_SEC" ]]; then
    log "FAIL check=${name}: no successful task for ${prog_age}s (> ${AISL_Q_PROGRESS_MAX_AGE_SEC}s) failed_last_24h=${fail24}"
    send_alert "$name" "FAIL" "AISHL worker shows no successful django_q_task for ${prog_age}s (threshold ${AISL_Q_PROGRESS_MAX_AGE_SEC}s) — qcluster may be down."
    FAILED=1; return
  fi
  log "OK check=${name}: failed_last_24h=${fail24} success_age=${prog_age}s"
  mark_ok "$name"
}

# Residual Created-container detection (t1143u: a stale Created relay-dev web
# container sat on contabo-b for 20h unnoticed; cmp-created-watchdog
# self-heals only on contabo-a). FAILs on any Created container older than
# CREATED_GRACE_SEC — fresh deploys pass through Created briefly, residuals
# do not. Removal stays a manual `docker rm` after inspection.
check_created_containers() {
  local name="docker-created" ids
  CREATED_GRACE_SEC="${CREATED_GRACE_SEC:-1800}"
  if ! command -v docker >/dev/null 2>&1; then
    log "WARN check=${name}: docker not found — skipping"
    return
  fi
  # shellcheck disable=SC2086
  ids="$(docker ps -a --filter status=created --format '{{.ID}}' 2>/dev/null || true)"
  local stale="" id created epoch age now
  now="$(date +%s)"
  # shellcheck disable=SC2086
  for id in $ids; do
    created="$(docker inspect -f '{{.Created}}' "$id" 2>/dev/null || true)"
    epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
    age=$(( now - epoch ))
    if [[ "$epoch" -le 0 ]]; then
      stale="$stale ${id}(age-unknown)"
    elif [[ "$age" -gt "$CREATED_GRACE_SEC" ]]; then
      stale="$stale ${id}(${age}s)"
    fi
  done
  if [[ -n "${stale// /}" ]]; then
    log "FAIL check=${name}: stale Created container(s):${stale} (grace ${CREATED_GRACE_SEC}s)"
    send_alert "$name" "FAIL" "Stale Created container(s) on $(hostname):${stale} — a Coolify deploy created but never started them (cf. t658u). Inspect, then 'docker rm' the leftover or 'docker start' it."
    FAILED=1; return
  fi
  log "OK check=${name}: no stale Created containers"
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

if [[ "${CHECK_CMP_CALLBACKS:-0}" == "1" ]]; then
  check_cmp_callbacks
fi

# AISHL django_q failure/progress — enable only on the PG data host.
if [[ "${CHECK_AISL_Q:-0}" == "1" ]]; then
  check_aisl_q
fi

if [[ -n "${APP_URLS:-}" ]]; then
  # shellcheck disable=SC2086
  for pair in $APP_URLS; do
    app="${pair%%=*}"; url="${pair#*=}"
    [[ -n "$app" && -n "$url" && "$url" != "$pair" ]] || { log "WARN: skipping malformed APP_URLS entry: ${pair}"; continue; }
    if [[ "$SKIP_PUBLIC_HTTP_CHECKS" == "1" ]] && is_public_url "$url"; then
      log "SKIP check=http-${app}: public URL (SKIP_PUBLIC_HTTP_CHECKS=1; contabo-b owns public pages)"
      continue
    fi
    check_http "$app" "$url"
  done
else
  log "WARN: APP_URLS is empty — no HTTP checks configured (fill /etc/coolify-healthcheck.env)"
fi

if [[ -n "${CONTENT_CHECKS:-}" ]]; then
  # shellcheck disable=SC2086
  for entry in $CONTENT_CHECKS; do
    app="${entry%%=*}"; rest="${entry#*=}"
    url="${rest%%::*}"; marker="${rest#*::}"
    if [[ -z "$app" || -z "$url" || -z "$marker" || "$url" == "$rest" || "$marker" == "$rest" ]]; then
      log "WARN: skipping malformed CONTENT_CHECKS entry: ${entry} (want name=url::marker)"
      continue
    fi
    if [[ "$SKIP_PUBLIC_HTTP_CHECKS" == "1" ]] && is_public_url "$url"; then
      log "SKIP check=content-${app}: public URL (SKIP_PUBLIC_HTTP_CHECKS=1; contabo-b owns public pages)"
      continue
    fi
    check_content "$app" "$url" "$marker"
  done
else
  log "WARN: CONTENT_CHECKS is empty — no content-marker checks configured (status-only APP_URLS miss wrong-content incidents)"
fi


if [[ "${SKIP_DISK_CHECK:-0}" == "1" ]]; then
  log "SKIP check=disk-root (SKIP_DISK_CHECK=1)"
else
  check_disk
fi

# Residual Created-container detection runs on every node with docker
# (self-heal stays with cmp-created-watchdog on contabo-a only).
check_created_containers

if [[ "${SKIP_BACKUP_CHECKS:-0}" == "1" ]]; then
  log "SKIP backup dump/WAL freshness (SKIP_BACKUP_CHECKS=1)"
else
  check_dump_freshness
  check_wal_freshness
fi

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
