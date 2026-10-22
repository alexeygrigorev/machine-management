#!/usr/bin/env bash
# Stage WAL archiving on a Coolify Contabo Postgres instance (docs-ready).
#
# What it does: ALTER SYSTEM sets wal_level=replica, archive_mode=on,
# archive_command + archive_timeout — then VERIFIES the staged values.
# What it NEVER does: restart Postgres. archive_mode=on takes effect only
# after a restart, which is an operator-window action (seconds of write
# downtime per instance). This script prints the exact restart command and
# the post-restart verification; the operator runs the restart by hand.
#
# Design note: the postgres:16 container has NO aws CLI and Coolify mounts
# no helper scripts into it, so archive_command CANNOT upload to S3
# directly. Instead it spools each segment into PGDATA/wal_spool (host
# visible via the docker volume) and coolify-wal-shipper.sh (host cron,
# every minute) gzips + uploads to S3 with read-back. See README "WAL
# rollout order" and coolify-wal-shipper.sh header for the full chain.
#
# Usage (on contabo-b, Coolify manages the containers):
#   sudo ./coolify-wal-enable.sh --stack pg-shared --container <name>
#   sudo ./coolify-wal-enable.sh --stack pg-relay  --container <name>
#   # then, in the maintenance window, run the printed docker restart + verify.
#
# Preconditions checked: shipper at /usr/local/sbin/coolify-wal-shipper.sh,
# /etc/coolify-wal-archive.env exists (root 600), container reachable.
set -euo pipefail

STACK=""; CONTAINER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) STACK="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    *) echo "usage: $0 --stack <pg-shared|pg-relay> --container <docker-name>" >&2; exit 2 ;;
  esac
done
[[ "$STACK" == "pg-shared" || "$STACK" == "pg-relay" ]] || { echo "bad --stack" >&2; exit 2; }
[[ -n "$CONTAINER" ]] || { echo "missing --container" >&2; exit 2; }

SHIPPER="/usr/local/sbin/coolify-wal-shipper.sh"
[[ -x "$SHIPPER" ]] || { echo "ERROR: shipper missing: $SHIPPER (install coolify-wal-shipper.sh first)" >&2; exit 1; }
[[ -f /etc/coolify-wal-archive.env ]] || { echo "ERROR: /etc/coolify-wal-archive.env missing (root 600, see backups/README.md)" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "ERROR: container not running: $CONTAINER" >&2; exit 1; }

PGUSER="${PGUSER:-pgadmin}"
SPOOL_DIR="/var/lib/postgresql/data/wal_spool"
ARCHIVE_CMD="cp %p ${SPOOL_DIR}/.%f.tmp && mv ${SPOOL_DIR}/.%f.tmp ${SPOOL_DIR}/%f"

echo "Staging WAL archiving on ${CONTAINER} (stack=${STACK}) ..."
docker exec -u postgres "$CONTAINER" mkdir -p "$SPOOL_DIR"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET wal_level = 'replica';"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET archive_mode = 'on';"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET archive_command = '${ARCHIVE_CMD}';"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET max_wal_senders = '10';"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET archive_timeout = '300';"

echo "--- staged (pending restart) ---"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -tAc \
  "SELECT name, setting, pending_restart FROM pg_settings WHERE name IN ('wal_level','archive_mode','archive_command','max_wal_senders','archive_timeout') ORDER BY 1;"

cat <<EOF

STAGED — restart still required (NOT done by this script).
In the maintenance window, run:

  docker restart ${CONTAINER}
  sleep 10
  docker exec ${CONTAINER} psql -U ${PGUSER} -d postgres -tAc "SHOW archive_mode; SHOW archive_command;"
  # expect: on | cp %p .../wal_spool/.%f.tmp && mv ... (spool pattern)
  docker exec ${CONTAINER} psql -U ${PGUSER} -d postgres -c "SELECT pg_switch_wal();"
  # then confirm s3://<bucket>/coolify/postgres/${STACK}/wal/<today>/*.gz appears
  # (via the per-minute coolify-wal-shipper.sh cron on the host)

Rollback (if archiving misbehaves):
  docker exec ${CONTAINER} psql -U ${PGUSER} -d postgres -c "ALTER SYSTEM SET archive_mode = 'off';"
  docker restart ${CONTAINER}
EOF
