#!/usr/bin/env bash
# Contabo dump/WAL export-size + freshness → VictoriaMetrics (t1146u–t1153u).
# Contabo path = nightly pg_dump .dump.gz → S3 (NO parquet/SQLite).
set -euo pipefail

ENV_FILE="${COOLIFY_BACKUP_METRICS_ENV:-/etc/coolify-backup-metrics.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DUMP_DIR="${DUMP_DIR:-/var/backups/coolify-postgres}"
WAL_STATE_DIR="${WAL_SHIPPER_STATE_DIR:-/var/lib/coolify-wal-shipper}"
VM_PUSH_URL="${VM_PUSH_URL:-http://10.100.0.1:8428/api/v1/import/prometheus}"
HOST_LABEL="${HOST_LABEL:-contabo-b}"
EXPECT_DBS="${EXPECT_DBS:-cmp aisl website relay}"
LOCK_FILE="${LOCK_FILE:-/var/lock/coolify-backup-metrics.lock}"
LOG_FILE="${LOG_FILE:-/var/log/coolify-backup-metrics.log}"

log() { printf '%s backup-metrics %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE" >&2; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "skip: lock held"; exit 0; }

NOW="$(date +%s)"
PAYLOAD=""
emit() { PAYLOAD+="$1 $2"$'\n'; }

used_pct="$(df -P / | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')"
avail_kb="$(df -P / | awk 'NR==2 { print $4 }')"
if [[ "$used_pct" =~ ^[0-9]+$ ]]; then
  emit "coolify_backup_disk_used_percent{host=\"${HOST_LABEL}\",mount=\"/\"}" "$used_pct"
fi
if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
  emit "coolify_backup_disk_avail_bytes{host=\"${HOST_LABEL}\",mount=\"/\"}" "$((avail_kb * 1024))"
fi

for db in $EXPECT_DBS; do
  f="$(ls -1t "$DUMP_DIR"/${db}-*.dump.gz 2>/dev/null | head -1 || true)"
  if [[ -z "$f" || ! -f "$f" ]]; then
    emit "coolify_backup_dump_present{host=\"${HOST_LABEL}\",db=\"${db}\"}" "0"
    continue
  fi
  size="$(stat -c%s "$f")"
  mtime="$(stat -c%Y "$f")"
  age=$(( NOW - mtime )); [[ "$age" -lt 0 ]] && age=0
  emit "coolify_backup_dump_present{host=\"${HOST_LABEL}\",db=\"${db}\"}" "1"
  emit "coolify_backup_dump_size_bytes{host=\"${HOST_LABEL}\",db=\"${db}\"}" "$size"
  emit "coolify_backup_dump_mtime_unixtime{host=\"${HOST_LABEL}\",db=\"${db}\"}" "$mtime"
  emit "coolify_backup_dump_age_seconds{host=\"${HOST_LABEL}\",db=\"${db}\"}" "$age"
done

shopt -s nullglob
for sf in "$WAL_STATE_DIR"/last-success-*; do
  stack="${sf##*/last-success-}"
  ts_raw="$(tr -d '[:space:]' < "$sf" 2>/dev/null || true)"
  if [[ -z "$ts_raw" ]]; then
    emit "coolify_backup_wal_last_success_unixtime{host=\"${HOST_LABEL}\",stack=\"${stack}\"}" "0"
    continue
  fi
  ts="$(date -u -d "$ts_raw" +%s 2>/dev/null || echo 0)"
  age=$(( NOW - ts )); [[ "$age" -lt 0 ]] && age=0
  emit "coolify_backup_wal_last_success_unixtime{host=\"${HOST_LABEL}\",stack=\"${stack}\"}" "$ts"
  emit "coolify_backup_wal_age_seconds{host=\"${HOST_LABEL}\",stack=\"${stack}\"}" "$age"
done
shopt -u nullglob

emit "coolify_backup_metrics_last_run_unixtime{host=\"${HOST_LABEL}\"}" "$NOW"

[[ -n "$PAYLOAD" ]] || { log "ERROR: empty payload"; exit 1; }

code="$(curl -sS -o /tmp/coolify-backup-metrics-push.body -w '%{http_code}' \
  -m 15 -X POST --data-binary "$PAYLOAD" "$VM_PUSH_URL" || echo curl_fail)"
if [[ "$code" != "204" && "$code" != "200" ]]; then
  log "ERROR: VM push failed code=${code} body=$(head -c 200 /tmp/coolify-backup-metrics-push.body 2>/dev/null)"
  exit 1
fi
log "OK pushed host=${HOST_LABEL} code=${code} bytes=${#PAYLOAD}"
