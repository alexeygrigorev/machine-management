#!/usr/bin/env bash
# Stage WAL archiving on a Coolify Contabo Postgres instance (docs-ready).
#
# What it does: ALTER SYSTEM sets wal_level=replica, archive_mode=on,
# archive_command + wal_keepalive slots — then VERIFIES the staged values.
# What it NEVER does: restart Postgres. archive_mode=on takes effect only
# after a restart, which is an operator-window action (seconds of write
# downtime per instance). This script prints the exact restart command and
# the post-restart verification; the operator runs the restart by hand.
#
# Usage (on contabo-b, Coolify manages the containers):
#   sudo ./coolify-wal-enable.sh --stack pg-shared --container <name>
#   sudo ./coolify-wal-enable.sh --stack pg-relay  --container <name>
#   # then, in the maintenance window, run the printed docker restart + verify.
#
# Preconditions checked: helper present at /usr/local/sbin/coolify-wal-archive.sh,
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

HELPER="/usr/local/sbin/coolify-wal-archive.sh"
[[ -x "$HELPER" ]] || { echo "ERROR: helper missing: $HELPER (install coolify-wal-archive.sh first)" >&2; exit 1; }
[[ -f /etc/coolify-wal-archive.env ]] || { echo "ERROR: /etc/coolify-wal-archive.env missing (root 600, see backups/README.md)" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "ERROR: container not running: $CONTAINER" >&2; exit 1; }

PGUSER="${PGUSER:-pgadmin}"
ARCHIVE_CMD="${HELPER} ${STACK} %p %f"

echo "Staging WAL archiving on ${CONTAINER} (stack=${STACK}) ..."
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
  # expect: on | ${ARCHIVE_CMD}
  docker exec ${CONTAINER} psql -U ${PGUSER} -d postgres -c "SELECT pg_switch_wal();"
  # then confirm s3://<bucket>/coolify/postgres/${STACK}/wal/<today>/*.gz appears

Rollback (if archiving misbehaves):
  docker exec ${CONTAINER} psql -U ${PGUSER} -d postgres -c "ALTER SYSTEM SET archive_mode = 'off';"
  docker restart ${CONTAINER}
EOF
