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
#      Created-container detection. WAL freshness is idle-tolerant: a stale
#      shipper timestamp is verified against pg_stat_archiver + spool before
#      paging, so an idle DB is not a FAIL while a real archiving/shipper
#      stop still pages (a3348a3e/t1862u).
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

# Reserved test hosts must never become live monitor targets, even when public
# checks are skipped on this node. Validate before probes, state or mail writes.
validate_target_hosts() {
  local setting entry url authority host
  for setting in APP_URLS CONTENT_CHECKS; do
    for entry in ${!setting:-}; do
      url="${entry#*=}"; url="${url%%::*}"
      authority="${url#*://}"; authority="${authority%%[/?#]*}"
      authority="${authority##*@}"
      host="${authority%%:*}"; host="${host,,}"; host="${host%.}"
      case "$host" in
        example.test|*.example.test)
          log "ERROR: reserved example.test host in ${setting}; use a real health URL"
          return 1
          ;;
      esac
    done
  done
}
validate_target_hosts || exit 2

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
# Idle-tolerant verification (a3348a3e/t1862u, 2026-10-28T02:55Z false page):
# before paging a stale last-success, verify the live archiver (see
# wal_idle_verdict). 1 = verify (default), 0 = page on age alone (old behavior).
WAL_IDLE_VERIFY="${WAL_IDLE_VERIFY:-1}"
# The shipper publishes last-success by truncate+write; a concurrent read can
# land in the sub-ms window and see an empty file (the 02:55Z page: GNU
# date -d '' = today 00:00Z -> age exactly since midnight, plus empty `last=`).
# One bounded re-read before failing; the repo shipper also publishes
# atomically (mktemp+mv) since 91e25fd.
WAL_IDLE_REREAD_WAIT_SEC="${WAL_IDLE_REREAD_WAIT_SEC:-0.5}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"
DISK_WARN_RECOVER_PERCENT="${DISK_WARN_RECOVER_PERCENT:-83}"
DISK_MAX_PERCENT="${DISK_MAX_PERCENT:-92}"
DISK_RECOVER_PERCENT="${DISK_RECOVER_PERCENT:-90}"
DISK_FAIL_CONSECUTIVE="${DISK_FAIL_CONSECUTIVE:-2}"
# Dumps and WAL markers belong to contabo-b (vmd210005). Select the data
# host by identity, never by path existence: losing both directories there
# must still alert. Explicit SKIP_BACKUP_CHECKS=0 enables missing-path drills
# and data hosts with another hostname; =1 disables local backup checks.
BACKUP_HOSTNAME="${BACKUP_HOSTNAME:-vmd210005}"
SKIP_BACKUP_CHECKS_AUTO=0
if [[ -z "${SKIP_BACKUP_CHECKS:-}" ]]; then
  if [[ "$(hostname -s)" == "$BACKUP_HOSTNAME" || "$(hostname -s)" == contabo-b ]]; then
    SKIP_BACKUP_CHECKS=0
  else
    SKIP_BACKUP_CHECKS=1
    SKIP_BACKUP_CHECKS_AUTO=1
  fi
else
  SKIP_BACKUP_CHECKS="${SKIP_BACKUP_CHECKS:-0}"
fi
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
#   APP_URLS="coolify_ui=http://169.58.119.163:8000/ relay=https://relay.datatalks.club/health/"
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
# curl 35 (SSL connect error / Recv failure: Connection reset by peer) and 56
# (recv failure) are retried exactly ONCE after a short sleep before FAIL.
# A second 35/56 still FAILs and alerts as usual.
HTTP_RESET_RETRY_SLEEP_SEC="${HTTP_RESET_RETRY_SLEEP_SEC:-5}"

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
ALERT_OPS_TO="${ALERT_OPS_TO:-dev@dtcdev.click}"
ALERT_FROM="${ALERT_FROM:-alerts@dtcdev.click}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-DTC Alerts}"
ALERT_MSMTP_ACCOUNT="${ALERT_MSMTP_ACCOUNT:-alerts}"
ALERT_REPEAT_MIN="${ALERT_REPEAT_MIN:-60}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ops-daily-digest.sh}"

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
      "$DIGEST_SCRIPT" --enqueue "coolify-healthcheck" "$chk" "$lvl" "$msg" 2>/dev/null || true
  fi
}
# Suppress RECOVERED mail when the FAIL lasted shorter than this many seconds
# (t1273u/t1274u: cut rapid FAIL→RECOVERED pair spam for one-tick flakes).
# FAIL itself still pages immediately — do NOT raise FAIL_STREAK for prod HTTP
# (AISHL Coolify replace 503 must remain visible until zero-downtime is fixed).
RECOVER_NOTIFY_MIN_SEC="${RECOVER_NOTIFY_MIN_SEC:-600}"
# When 1, skip APP_URLS + CONTENT_CHECKS that hit public hostnames (dedupe:
# only one Contabo node should page for the same public URL). Keep local
# checks (127.0.0.1 / 10.100.0.x). Set on contabo-a; leave 0 on contabo-b.
SKIP_PUBLIC_HTTP_CHECKS="${SKIP_PUBLIC_HTTP_CHECKS:-0}"

# --- latency probes (f5d8e22b: TTFB + total per URL into VictoriaMetrics) ---
# Space-separated name=url::service triples. Probe list covers AC2:
# CMP home + one course page, AISHL home + one content page, Relay /health,
# website home + /events/past, plus the 3 AWS-hosted services for AC1
# (hub/ops/dapier never pass through the Contabo Traefik proxies, so probes
# are their only per-service latency source). Service label groups PromQL p95
# per service (cmp, aisl, relay, website, hub, ops, dapier). Fleet dedup
# (t1634u/6e626719) applies via host env overrides. TTFB/total recorded even
# on HTTP 4xx/5xx (status label preserves the code); curl transport failures
# record -1.
LATENCY_PROBES="${LATENCY_PROBES-cmp_home=https://courses.datatalks.club/::cmp cmp_course=https://courses.datatalks.club/ml-zoomcamp-2026/::cmp aisl_home=https://aishippinglabs.com/::aisl aisl_content=https://aishippinglabs.com/blog/what-does-an-ai-engineer-do::aisl relay_health=https://relay.datatalks.club/health/::relay website_home=https://datatalks.club/::website website_events_past=https://datatalks.club/events/past::website hub_home=https://hub.dtcdev.click/::hub ops_home=https://ops.dtcdev.click/::ops dapier_home=https://dapier.dtcdev.click/::dapier}"
LATENCY_PUSH_ENABLED="${LATENCY_PUSH_ENABLED:-1}"
# Contabo hosts reach VM over WireGuard; Hetzner deadman overrides via SSH.
LATENCY_PUSH_URL="${LATENCY_PUSH_URL:-http://10.100.0.1:8429/api/v1/import/prometheus}"
LATENCY_PUSH_TIMEOUT="${LATENCY_PUSH_TIMEOUT:-10}"
# Slowness alert (AC3 probe leg): TTFB > 3s sustained >=10min -> mail ONLY to
# LATENCY_ALERT_TO (default dev@dtcdev.click) from alerts@dtcdev.click, with
# RECOVERED, max 1 repeat/hour, hysteresis (fire 3.0s, recover 2.5s).
LATENCY_TTFB_WARN_SEC="${LATENCY_TTFB_WARN_SEC:-3}"
LATENCY_TTFB_RECOVER_SEC="${LATENCY_TTFB_RECOVER_SEC:-2.5}"
LATENCY_SUSTAIN_SEC="${LATENCY_SUSTAIN_SEC:-600}"
LATENCY_ALERT_TO="${LATENCY_ALERT_TO:-dev@dtcdev.click}"
LATENCY_STATE_SUFFIX="${LATENCY_STATE_SUFFIX:-latency}"

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
  SEND_ALERT_DELIVERED=0
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
      SEND_ALERT_DELIVERED=1
      return 0  # still failing, recently alerted — dedupe
    fi
  fi
  local full_subject="[coolify-healthcheck] ${subject} (${name})"
  local sent="no"
  # Policy (t1885u / 3bf25bda AC2 & AC4):
  # 1. RECOVERED, WARN, dev-surface checks (*_dev), and drills/tests NEVER email alexey@.
  # 2. Unconfigured wrong-host invocations (e.g. bare run on RMTHZ where /etc/coolify-healthcheck.env
  #    is absent and real /usr/bin/msmtp is on PATH) strip alexey@ so wrong-host runs cannot page alexey@.
  local effective_to="$ALERT_TO"
  local msmtp_resolved
  msmtp_resolved="$(command -v msmtp 2>/dev/null || true)"
  if [[ "$is_recovery" -eq 1 || "$subject" == WARN* || "$name" == *_dev || "$name" == *-dev || "$name" == *DRILL* || "$name" == *TEST* || "${DRILL_MODE:-0}" == "1" || "${TEST_MODE:-0}" == "1" ]]; then
    enqueue_digest "$name" "$subject" "$body"
    effective_to="$(strip_personal_recipients "$ALERT_TO")"
  elif [[ ! -f "$ENV_FILE" && "$msmtp_resolved" == "/usr/bin/msmtp" && "${COOLIFY_HEALTHCHECK_ALLOW_UNCONFIGURED_PROD_MAIL:-0}" != "1" ]]; then
    log "WARN check=${name}: unconfigured host (${ENV_FILE} absent, real msmtp) — stripping personal recipients"
    effective_to="$(strip_personal_recipients "$ALERT_TO")"
  fi
  local to_csv="${effective_to// /,}"
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
    log "WARN: no MTA (sendmail/msmtp) on this host — alert for ${name} logged only; install msmtp and configure SMTP (see README)"
  fi
  log "ALERT check=${name} subject='${full_subject}' via=${sent} to=${to_csv}"
  if [[ "$sent" == "no" ]]; then
    log "FAIL check=mail-${name}: delivery failed; retaining state for retry"
    FAILED=1
    return 0
  fi
  SEND_ALERT_DELIVERED=1
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
  local attempt=1 max=$((HTTP_RETRIES + 1)) code rc err reset_retried=0
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
    # Transient: TLS/recv reset (35/56). Retry exactly once.
    if [[ ( "$rc" -eq 35 || "$rc" -eq 56 ) && "$reset_retried" -eq 0 ]]; then
      log "WARN check=http-retry: url=${url} rc=${rc} detail=$(tr -d '\n' <"$err"); one reset retry after ${HTTP_RESET_RETRY_SLEEP_SEC}s" >&2
      rm -f "$err"
      reset_retried=1
      sleep "$HTTP_RESET_RETRY_SLEEP_SEC"
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
  local attempt=1 max=$((HTTP_RETRIES + 1)) err reset_retried=0
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
    if [[ ( "$rc" -eq 35 || "$rc" -eq 56 ) && "$reset_retried" -eq 0 ]]; then
      log "WARN check=content-retry: url=${url} rc=${rc} detail=$(tr -d '\n' <"$err"); one reset retry after ${HTTP_RESET_RETRY_SLEEP_SEC}s"
      rm -f "$err"
      reset_retried=1
      sleep "$HTTP_RESET_RETRY_SLEEP_SEC"
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

# Latency probes (f5d8e22b AC2+AC3): TTFB + total per URL into VictoriaMetrics.
# Metrics (Prometheus exposition, pushed to LATENCY_PUSH_URL):
#   probe_ttfb_seconds{probe,service,url_host,status,host}
#   probe_total_seconds{probe,service,url_host,status,host}
# url_host is the URL authority only (no query string / PII). status is the
# HTTP code or "000" on transport failure (values -1).
LATENCY_METRICS_FILE=""
trap '[[ -z "${LATENCY_METRICS_FILE:-}" ]] || rm -f -- "$LATENCY_METRICS_FILE"' EXIT
latency_metrics_init() {
  LATENCY_METRICS_FILE="$(mktemp)" || return 1
}
latency_metrics_emit() {
  # $1=probe $2=service $3=url_host $4=status $5=ttfb $6=total
  local probe="$1" service="$2" uhost="$3" status="$4" ttfb="$5" total="$6"
  local hname
  hname="$(hostname)"
  {
    printf 'probe_ttfb_seconds{probe="%s",service="%s",url_host="%s",status="%s",host="%s"} %s\n' \
      "$probe" "$service" "$uhost" "$status" "$hname" "$ttfb"
    printf 'probe_total_seconds{probe="%s",service="%s",url_host="%s",status="%s",host="%s"} %s\n' \
      "$probe" "$service" "$uhost" "$status" "$hname" "$total"
  } >> "$LATENCY_METRICS_FILE"
}
latency_metrics_push() {
  [[ "${LATENCY_PUSH_ENABLED:-1}" == "1" ]] || return 0
  [[ -s "${LATENCY_METRICS_FILE:-}" ]] || return 0
  [[ -n "${LATENCY_PUSH_URL:-}" ]] || { log "WARN latency-push: LATENCY_PUSH_URL empty, skipping"; return 0; }
  if curl -fsS --max-time "$LATENCY_PUSH_TIMEOUT" --data-binary "@$LATENCY_METRICS_FILE" \
      "$LATENCY_PUSH_URL" -o /dev/null 2>/dev/null; then
    log "OK latency-push: pushed $(grep -c '^probe_' "$LATENCY_METRICS_FILE") series to VM"
  else
    log "WARN latency-push: push to VM failed (metrics kept in log only)"
  fi
  rm -f "$LATENCY_METRICS_FILE"
  LATENCY_METRICS_FILE=""
}
send_latency_alert() {
  # $1=probe $2=subject-suffix $3=body — always to LATENCY_ALERT_TO only.
  local probe="$1" subject="$2" body="$3"
  local name="latency-${probe}-${LATENCY_STATE_SUFFIX}"
  local state_file="${STATE_DIR}/${name}.state"
  local STATUS="" LAST_ALERT=0 FIRST_EXCEED=0 FAIL_SINCE=0
  local last_alert=0 last_status="" first_exceed=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_alert="${LAST_ALERT:-0}"; last_status="${STATUS:-}"; first_exceed="${FIRST_EXCEED:-0}"
  fi
  local is_recovery=0
  [[ "$subject" == RECOVERED* ]] && is_recovery=1
  if [[ "$is_recovery" -eq 0 && "$last_status" == "FAIL" ]]; then
    local elapsed_min=$(( (NOW - last_alert) / 60 ))
    if [[ "$elapsed_min" -lt 60 ]]; then
      printf 'STATUS=FAIL\nLAST_ALERT=%s\nFIRST_EXCEED=%s\n' "$last_alert" "$first_exceed" > "$state_file"
      return 0
    fi
  fi
  local saved_to="$ALERT_TO"
  ALERT_TO="$LATENCY_ALERT_TO"
  send_alert "$name" "$subject" "$body"
  ALERT_TO="$saved_to"
  [[ "${SEND_ALERT_DELIVERED:-0}" == "1" ]] || return 0
  # send_alert wrote state under latency name with FAIL_SINCE; preserve FIRST_EXCEED.
  if [[ -f "$state_file" ]]; then
    if [[ "$is_recovery" -eq 1 ]]; then
      printf 'STATUS=OK\nLAST_ALERT=0\nFIRST_EXCEED=0\n' > "$state_file"
    else
      local cur_alert=0
      # shellcheck disable=SC1090
      source "$state_file" || true
      cur_alert="${LAST_ALERT:-$NOW}"
      printf 'STATUS=FAIL\nLAST_ALERT=%s\nFIRST_EXCEED=%s\n' "$cur_alert" "${first_exceed:-$NOW}" > "$state_file"
    fi
  fi
}
probe_latency() {
  # $1=probe $2=url $3=service — measures TTFB/total, emits metrics, alerts on sustained slowness.
  local probe="$1" url="$2" service="$3"
  local uhost status ttfb total rc out
  uhost="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | sed -E 's#[:/].*##')"
  out="$(curl -sS -L -o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}' \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$url" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    status="000"; ttfb="-1"; total="-1"
    log "WARN latency probe=${probe} service=${service} url_host=${uhost}: curl rc=${rc} detail='$(echo "$out" | head -c 160)'"
  else
    status="$(echo "$out" | awk '{print $1}')"
    ttfb="$(echo "$out" | awk '{print $2}')"
    total="$(echo "$out" | awk '{print $3}')"
    [[ "$ttfb" =~ ^[0-9.]+$ ]] || ttfb="-1"
    [[ "$total" =~ ^[0-9.]+$ ]] || total="-1"
    [[ "$status" =~ ^[0-9]{3}$ ]] || status="000"
    log "OK latency probe=${probe} service=${service} url_host=${uhost} status=${status} ttfb=${ttfb}s total=${total}s"
  fi
  if [[ -n "${LATENCY_METRICS_FILE:-}" ]]; then
    latency_metrics_emit "$probe" "$service" "$uhost" "$status" "$ttfb" "$total"
  fi
  # Slowness leg (AC3): TTFB > warn sustained >= SUSTAIN_SEC -> FAIL (dev@ only).
  # Hysteresis: recover only when TTFB < recover threshold (transport fail = no recover).
  local state_file="${STATE_DIR}/latency-${probe}-${LATENCY_STATE_SUFFIX}.state"
  local STATUS="" LAST_ALERT=0 FIRST_EXCEED=0 FAIL_SINCE=0
  local last_status="" first_exceed=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    last_status="${STATUS:-}"; first_exceed="${FIRST_EXCEED:-0}"
  fi
  local is_slow=0 is_recovered=0
  if [[ "$ttfb" != "-1" ]] && awk "BEGIN{exit !( $ttfb > $LATENCY_TTFB_WARN_SEC )}"; then
    is_slow=1
  fi
  if [[ "$ttfb" != "-1" ]] && awk "BEGIN{exit !( $ttfb < $LATENCY_TTFB_RECOVER_SEC )}"; then
    is_recovered=1
  fi
  if [[ "$is_slow" -eq 1 ]]; then
    [[ "$first_exceed" -gt 0 ]] || first_exceed="$NOW"
    printf 'STATUS=%s\nLAST_ALERT=%s\nFIRST_EXCEED=%s\n' \
      "${last_status:-PENDING}" "${LAST_ALERT:-0}" "$first_exceed" > "$state_file"
    local sustained=$(( NOW - first_exceed ))
    if [[ "$sustained" -ge "$LATENCY_SUSTAIN_SEC" ]]; then
      log "FAIL latency probe=${probe}: TTFB ${ttfb}s > ${LATENCY_TTFB_WARN_SEC}s sustained ${sustained}s"
      send_latency_alert "$probe" "FAIL" "Slowness: probe '${probe}' (${service} ${uhost}) TTFB ${ttfb}s > ${LATENCY_TTFB_WARN_SEC}s sustained ${sustained}s (threshold ${LATENCY_SUSTAIN_SEC}s). Total ${total}s status ${status}."
      FAILED=1
    else
      log "WARN latency probe=${probe}: TTFB ${ttfb}s above threshold, sustained ${sustained}s (< ${LATENCY_SUSTAIN_SEC}s) — no page yet"
    fi
  else
    if [[ "$last_status" == "FAIL" && "$is_recovered" -eq 1 ]]; then
      log "OK latency probe=${probe}: TTFB ${ttfb}s recovered (< ${LATENCY_TTFB_RECOVER_SEC}s)"
      send_latency_alert "$probe" "RECOVERED" "Slowness recovered: probe '${probe}' (${service} ${uhost}) TTFB ${ttfb}s < ${LATENCY_TTFB_RECOVER_SEC}s."
    elif [[ "$last_status" == "FAIL" ]]; then
      FAILED=1
      log "WARN latency probe=${probe}: TTFB ${ttfb}s below fire threshold but above recover (${LATENCY_TTFB_RECOVER_SEC}s) — holding FAIL (hysteresis)"
    else
      printf 'STATUS=OK\nLAST_ALERT=0\nFIRST_EXCEED=0\n' > "$state_file"
    fi
  fi
}

check_disk() {
  local name="disk-root" used_pct
  local state_file="${STATE_DIR}/${name}.state"
  local prev_status="" prev_streak=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
    prev_status="${STATUS:-}"
    prev_streak="${DISK_STREAK:-0}"
  fi
  used_pct="$(df -BP / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  if [[ -z "$used_pct" || ! "$used_pct" =~ ^[0-9]+$ ]]; then
    log "FAIL check=${name}: could not parse df"
    send_alert "$name" "FAIL" "Unable to parse root filesystem usage on $(hostname)."
    FAILED=1; return
  fi
  # Hysteresis + sustained breach (t1885u AC3):
  # - PAGE (FAIL) when used_pct >= DISK_MAX_PERCENT (92%, i.e. <=8% free) sustained across
  #   DISK_FAIL_CONSECUTIVE runs, staying in FAIL until <= DISK_RECOVER_PERCENT (90%).
  # - DIGEST (WARN) when used_pct >= DISK_WARN_PERCENT (85%), staying in WARN until
  #   <= DISK_WARN_RECOVER_PERCENT (83%). Never pages alexey@.
  local crit_thr="$DISK_MAX_PERCENT"
  local warn_thr="$DISK_WARN_PERCENT"
  if [[ "$prev_status" == "FAIL" ]]; then
    crit_thr=$(( DISK_RECOVER_PERCENT + 1 ))
    warn_thr=$(( DISK_WARN_RECOVER_PERCENT + 1 ))
  fi
  if [[ "$used_pct" -ge "$crit_thr" ]]; then
    local streak=$(( prev_streak + 1 ))
    if [[ "$streak" -lt "$DISK_FAIL_CONSECUTIVE" ]]; then
      log "WARN check=${name}: / at ${used_pct}% (>=${crit_thr}%) streak=${streak}/${DISK_FAIL_CONSECUTIVE} — holding PAGE until sustained breach"
      enqueue_digest "$name" "PENDING_CRIT" "Root filesystem on $(hostname) is ${used_pct}% full (streak ${streak}/${DISK_FAIL_CONSECUTIVE})."
      printf 'STATUS=%s\nLAST_ALERT=%s\nFAIL_SINCE=%s\nDISK_STREAK=%s\n' \
        "${prev_status:-PENDING}" "${LAST_ALERT:-0}" "${FAIL_SINCE:-0}" "$streak" > "$state_file"
      return
    fi
    log "FAIL check=${name}: / at ${used_pct}% (crit threshold ${DISK_MAX_PERCENT}%, streak=${streak})"
    send_alert "$name" "FAIL" "Root filesystem on $(hostname) is ${used_pct}% full (crit threshold ${DISK_MAX_PERCENT}%, recover <=${DISK_RECOVER_PERCENT}%). Contabo-b dumps/WAL must stay off-host; free space or prune."
    echo "DISK_STREAK=${streak}" >> "$state_file"
    FAILED=1; return
  elif [[ "$used_pct" -ge "$warn_thr" ]]; then
    log "WARN check=${name}: / at ${used_pct}% (warn threshold ${DISK_WARN_PERCENT}%, crit ${DISK_MAX_PERCENT}%) — digest only"
    enqueue_digest "$name" "WARN" "Root filesystem on $(hostname) is ${used_pct}% full (warn ${DISK_WARN_PERCENT}%, crit ${DISK_MAX_PERCENT}%)."
    printf 'STATUS=OK\nLAST_ALERT=%s\nFAIL_SINCE=0\nDISK_STREAK=0\n' "${LAST_ALERT:-0}" > "$state_file"
    return
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

# ---- WAL idle verification (a3348a3e/t1862u: 2026-10-28T02:55Z false page) ----
# A stale shipper last-success alone does not prove an archiving failure: an
# idle database switches no segments, so the timestamp legitimately ages past
# WAL_STALE_SECONDS with nothing wrong. Before paging, verify the live stack.
# Needs the local container (data host); anything unverifiable stays a FAIL —
# fail-closed, so a real stop still pages within ~WAL_STALE_SECONDS + cron
# period. Verdict is idle (no page) only when ALL hold:
#   - current WAL is within one segment of last_archived_wal (the segment
#     being written is never "pending"; >=2 behind = archive_command stalled),
#   - pg_stat_archiver failed_count is not above the previous verified run,
#   - the PGDATA spool holds no unshipped segment (shipper->S3 leg has
#     nothing queued — the DB cannot see this leg, so we check it directly).
wal_archiver_snapshot() {
  # $1=stack -> prints "last_archived_wal|since_last_arc_s|failed|archived|current_walfile"
  # on stdout; rc!=0 when the stack DB is unreachable or output is malformed.
  # Stack names look like pg-shared; the PG_* env vars use the bare suffix
  # (PG_SHARED_*, PG_RELAY_*), so strip the pg- prefix before uppercasing.
  local stack="$1" ind prefix u db ctr host port pass out rc
  prefix="${stack#pg-}"; prefix="${prefix^^}"
  ind="PGUSER_${prefix}";       u="${!ind:-pgadmin}"
  ind="PG_${prefix}_DB";        db="${!ind:-postgres}"
  ind="PG_${prefix}_CONTAINER"; ctr="${!ind:-}"
  ind="PGHOST_${prefix}";       host="${!ind:-127.0.0.1}"
  ind="PGPORT_${prefix}";       port="${!ind:-5432}"
  ind="PGPASSWORD_${prefix}";   pass="${!ind:-}"
  local sql="SELECT COALESCE(last_archived_wal,'-'),COALESCE(EXTRACT(EPOCH FROM (now()-last_archived_time))::bigint,-1),failed_count,archived_count,pg_walfile_name(pg_current_wal_lsn()) FROM pg_stat_archiver;"
  if [[ -n "$ctr" ]]; then
    out="$(timeout 20 docker exec -e PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' "$ctr" psql -X -U "$u" -d "$db" -tAc "$sql" 2>/dev/null)" && rc=0 || rc=$?
  else
    out="$(PGPASSWORD="$pass" PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=10000 -c default_transaction_read_only=on' timeout 20 psql -X -h "$host" -p "$port" -U "$u" -d "$db" -tAc "$sql" 2>/dev/null)" && rc=0 || rc=$?
  fi
  [[ "$rc" -eq 0 ]] || return "$rc"
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  [[ "$out" =~ ^(-|[0-9A-F]{24})\|-?[0-9]+\|[0-9]+\|[0-9]+\|[0-9A-F]{24}$ ]] || return 1
  printf '%s\n' "$out"
}

wal_spool_pending() {
  # $1=container -> prints count of unshipped spool segment files; rc!=0 when
  # unknown (no container/docker or unreadable PGDATA mount). Same mount
  # resolution as backups/coolify-wal-shipper.sh spool_for().
  local ctr="$1" mnt n
  if [[ -z "$ctr" ]] || ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  mnt="$(docker inspect "$ctr" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -n "$mnt" ]] || return 1
  n="$(find "$mnt/wal_spool" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l)" || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

wal_idle_verdict() {
  # $1=stack -> prints "idle <detail>" (stale age is expected, do not page) or
  # "fail <reason>" (page; reason doubles as the alert-text enrichment).
  local stack="$1" snap arc_wal since_arc failed archived cur_wal ctr spool prev=0
  local ind_container baseline="${STATE_DIR}/wal-archiver-failed-${stack}"  # NOT *.state: prune_stale_checks must never remove it
  if ! snap="$(wal_archiver_snapshot "$stack")"; then
    echo "fail archiver verification unavailable (pg_stat_archiver query failed) — failing closed"
    return 0
  fi
  IFS='|' read -r arc_wal since_arc failed archived cur_wal <<< "$snap"
  if [[ -f "$baseline" ]]; then
    prev="$(tr -d '[:space:]' < "$baseline")"
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  fi
  printf '%s\n' "$failed" > "$baseline"
  if [[ "$arc_wal" == "-" ]]; then
    echo "fail pg_stat_archiver has never archived a segment (failed_count=${failed}, current=${cur_wal})"
    return 0
  fi
  # Segment ids are fixed-width hex; the timeline prefix (chars 1-8) is equal
  # on a single primary, so compare the 64-bit segment counter only.
  local dist=$(( 16#${cur_wal:8} - 16#${arc_wal:8} ))
  if (( dist < 0 )); then
    echo "fail current WAL ${cur_wal} is behind last archived ${arc_wal} — archiver state inconsistent"
    return 0
  fi
  if (( dist >= 2 )); then
    echo "fail unarchived backlog: current segment ${cur_wal} vs last archived ${arc_wal} (${dist} segments), failed_count=${failed} — archive_command stalled"
    return 0
  fi
  if (( failed > prev )); then
    echo "fail pg_stat_archiver failed_count rose ${prev}->${failed} (last_archived ${arc_wal} ${since_arc}s ago, current ${cur_wal})"
    return 0
  fi
  ind_container="PG_${stack#pg-}_CONTAINER"; ind_container="${ind_container^^}"; ctr="${!ind_container:-}"
  if ! spool="$(wal_spool_pending "$ctr")"; then
    echo "fail spool state unknown (docker/PGDATA mount unavailable) — cannot rule out unshipped segments"
    return 0
  fi
  if (( spool > 0 )); then
    echo "fail spool holds ${spool} unshipped segment(s) — shipper/S3 leg stuck (last_archived ${arc_wal}, current ${cur_wal})"
    return 0
  fi
  echo "idle last_archived=${arc_wal} ${since_arc}s ago, failed_count=${failed} (flat vs ${prev}), archived_count=${archived}, spool empty, current=${cur_wal}"
}

check_wal_freshness() {
  local stack sf ts_raw ts age name verdict detail
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
    if [[ ! "$ts_raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      # Sub-ms truncate→write race with the shipper (2026-10-28T02:55Z false
      # page). One bounded re-read; still invalid -> fail closed below.
      sleep "$WAL_IDLE_REREAD_WAIT_SEC"
      ts_raw="$(tr -d '[:space:]' < "$sf")"
    fi
    # Reject empty/relative dates before GNU date can interpret them as midnight.
    if [[ ! "$ts_raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      log "FAIL check=${name}: invalid last-success timestamp"
      send_alert "$name" "FAIL" "WAL shipper last-success invalid for stack=${stack}: expected a UTC timestamp."
      FAILED=1; continue
    fi
    ts="$(date -u -d "$ts_raw" +%s 2>/dev/null || echo 0)"
    if [[ "$ts" -le 0 ]]; then
      log "FAIL check=${name}: unparseable timestamp '${ts_raw}'"
      send_alert "$name" "FAIL" "WAL shipper last-success unparseable for stack=${stack}: '${ts_raw}'"
      FAILED=1; continue
    fi
    age=$(( now - ts ))
    if [[ "$age" -gt "$WAL_STALE_SECONDS" ]]; then
      verdict=""
      [[ "${WAL_IDLE_VERIFY:-1}" == "1" ]] && verdict="$(wal_idle_verdict "$stack")"
      detail="${verdict#fail }"
      if [[ "$verdict" == idle* ]]; then
        log "OK check=${name}: age=${age}s > ${WAL_STALE_SECONDS}s but archiver idle — no page (last=${ts_raw}; ${verdict#idle })"
        mark_ok "$name"; continue
      fi
      log "FAIL check=${name}: age=${age}s > ${WAL_STALE_SECONDS}s last=${ts_raw}; ${detail}"
      send_alert "$name" "FAIL" "WAL archive stale for stack=${stack}: last success ${ts_raw} (age ${age}s, threshold ${WAL_STALE_SECONDS}s); ${detail} on $(hostname)."
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
  if [[ "${SKIP_CREATED_CHECK:-0}" == "1" ]]; then
    log "SKIP check=${name} (SKIP_CREATED_CHECK=1)"
    return
  fi
  CREATED_GRACE_SEC="${CREATED_GRACE_SEC:-1800}"
  if ! command -v docker >/dev/null 2>&1; then
    log "WARN check=${name}: docker not found — skipping"
    return
  fi
  # shellcheck disable=SC2086
  ids="$(docker ps -a --filter status=created --format '{{.ID}}' 2>/dev/null || true)"
  local stale="" id created epoch age now details
  now="$(date +%s)"
  # shellcheck disable=SC2086
  for id in $ids; do
    created="$(docker inspect -f '{{.Created}}' "$id" 2>/dev/null || true)"
    epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
    age=$(( now - epoch ))
    if [[ "$epoch" -le 0 || "$age" -gt "$CREATED_GRACE_SEC" ]]; then
      # Only ownership labels are emitted: arbitrary labels may hold secrets.
      details="$(docker inspect -f 'name={{.Name}} image={{.Config.Image}} agent.session={{index .Config.Labels "agent.session"}} coolify.app={{index .Config.Labels "coolify.applicationId"}} coolify.resourceName={{index .Config.Labels "coolify.resourceName"}} coolify.managed={{index .Config.Labels "coolify.managed"}}' "$id" 2>/dev/null || echo 'metadata-unavailable')"
      details="${details//$'\n'/ }"
      if [[ "$epoch" -le 0 ]]; then
        stale="$stale ${id}(age-unknown ${details})"
      else
        stale="$stale ${id}(${age}s ${details})"
      fi
    fi
  done
  if [[ -n "${stale// /}" ]]; then
    log "FAIL check=${name}: stale Created container(s):${stale} (grace ${CREATED_GRACE_SEC}s)"
    send_alert "$name" "FAIL" "Stale Created container(s) on $(hostname):${stale} — containers were created but never started; use ownership labels to attribute them. Inspect, then 'docker rm' the leftover or 'docker start' it."
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

# Latency probes (AC2): always run (even when SKIP_PUBLIC_HTTP_CHECKS=1 the
# probes still record metrics; slowness pages come only from contabo-b to
# avoid dual pages — contabo-a sets LATENCY_ALERT_ONLY_METRICS=1).
latency_metrics_init || log "WARN latency: mktemp failed, metrics in log only"
if [[ -n "${LATENCY_PROBES:-}" ]]; then
  # shellcheck disable=SC2086
  for entry in $LATENCY_PROBES; do
    probe="${entry%%=*}"; rest="${entry#*=}"
    url="${rest%%::*}"; service="${rest#*::}"
    if [[ -z "$probe" || -z "$url" || -z "$service" || "$url" == "$rest" || "$service" == "$rest" ]]; then
      log "WARN: skipping malformed LATENCY_PROBES entry: ${entry} (want name=url::service)"
      continue
    fi
    if [[ "${LATENCY_ALERT_ONLY_METRICS:-0}" == "1" ]]; then
      # Metrics-only mode (contabo-a): record TTFB/total, skip slowness paging.
      _saved_sustain="$LATENCY_SUSTAIN_SEC"
      LATENCY_SUSTAIN_SEC=999999999
      probe_latency "$probe" "$url" "$service"
      LATENCY_SUSTAIN_SEC="$_saved_sustain"
    else
      probe_latency "$probe" "$url" "$service"
    fi
  done
else
  log "WARN: LATENCY_PROBES is empty — no TTFB/total metrics recorded"
fi
latency_metrics_push

if [[ "${SKIP_DISK_CHECK:-0}" == "1" ]]; then
  log "SKIP check=disk-root (SKIP_DISK_CHECK=1)"
else
  check_disk
fi

# Residual Created-container detection runs on every node with docker
# (self-heal stays with cmp-created-watchdog on contabo-a only).
check_created_containers

if [[ "${SKIP_BACKUP_CHECKS:-0}" == "1" ]]; then
  if [[ "${SKIP_BACKUP_CHECKS_AUTO:-0}" == "1" ]]; then
    log "SKIP backup dump/WAL freshness (host=$(hostname -s); data host is ${BACKUP_HOSTNAME}/contabo-b)"
  else
    log "SKIP backup dump/WAL freshness (SKIP_BACKUP_CHECKS=1)"
  fi
  # Close old wrong-host incidents without claiming that a local artifact
  # became healthy. Failed delivery retains FAIL so the next run retries.
  for backup_check in ${EXPECT_DBS}; do
    backup_state="${STATE_DIR}/dump-${backup_check}.state"
    if [[ -f "$backup_state" ]] && grep -qx 'STATUS=FAIL' "$backup_state"; then
      send_alert "dump-${backup_check}" "RECOVERED" "Local backup check retired on $(hostname): dumps are monitored on ${BACKUP_HOSTNAME}/contabo-b. No local backup paths were evaluated."
    fi
  done
  for backup_check in ${WAL_STACKS}; do
    backup_state="${STATE_DIR}/wal-${backup_check}.state"
    if [[ -f "$backup_state" ]] && grep -qx 'STATUS=FAIL' "$backup_state"; then
      send_alert "wal-${backup_check}" "RECOVERED" "Local WAL check retired on $(hostname): WAL freshness is monitored on ${BACKUP_HOSTNAME}/contabo-b. No local WAL paths were evaluated."
    fi
  done
else
  check_dump_freshness
  check_wal_freshness
fi

prune_stale_checks() {
  # Prune state files for checks that are no longer configured (t1342u).
  [[ -d "$STATE_DIR" ]] || return 0
  local -A valid_checks=()
  valid_checks["pg-shared"]=1
  valid_checks["pg-relay"]=1
  valid_checks["docker-created"]=1
  valid_checks["disk-root"]=1
  valid_checks["aisl-q"]=1
  valid_checks["cmp-callbacks"]=1

  local pair app entry db stack probe rest
  if [[ -n "${APP_URLS:-}" ]]; then
    for pair in $APP_URLS; do
      app="${pair%%=*}"
      [[ -n "$app" ]] && valid_checks["http-${app}"]=1
    done
  fi
  if [[ -n "${CONTENT_CHECKS:-}" ]]; then
    for entry in $CONTENT_CHECKS; do
      app="${entry%%=*}"
      [[ -n "$app" ]] && valid_checks["content-${app}"]=1
    done
  fi
  if [[ -n "${LATENCY_PROBES:-}" ]]; then
    for entry in $LATENCY_PROBES; do
      probe="${entry%%=*}"
      [[ -n "$probe" ]] && valid_checks["latency-${probe}-${LATENCY_STATE_SUFFIX}"]=1
    done
  fi
  if [[ -n "${EXPECT_DBS:-}" ]]; then
    for db in $EXPECT_DBS; do
      [[ -n "$db" ]] && valid_checks["dump-${db}"]=1
    done
  fi
  if [[ -n "${WAL_STACKS:-}" ]]; then
    for stack in $WAL_STACKS; do
      [[ -n "$stack" ]] && valid_checks["wal-${stack}"]=1
    done
  fi

  local f cname
  for f in "$STATE_DIR"/*.state; do
    [[ -f "$f" ]] || continue
    cname="$(basename "$f" .state)"
    if [[ -z "${valid_checks[$cname]:-}" ]]; then
      log "PRUNE check=${cname}: check no longer in config — removed stale state"
      rm -f "$f"
    fi
  done
}

prune_stale_checks

if [[ "$FAILED" -ne 0 ]]; then
  log "CHECKS_FAILED"
  exit 1
fi
log "ALL_OK"
