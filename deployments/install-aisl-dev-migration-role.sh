#!/usr/bin/env bash
# Run on contabo-b as root. Never reads/prints application credentials or rows.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root on contabo-b' >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
container=ekm57uezdngrrscn0aqzidr8
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="/var/backups/aisl-dev-permissions-$stamp"
install -d -m 0700 "$backup"
# Include all original roles, memberships, owners and ACLs, without passwords or
# application data. Keep the snapshot private for a deliberate rollback.
docker exec "$container" sh -c 'pg_dumpall -U "$POSTGRES_USER" --roles-only --no-role-passwords' > "$backup/roles.sql"
docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" -d aisl_dev --schema-only' > "$backup/aisl-dev-schema.sql"
chmod 0600 "$backup/"*.sql
docker exec -i "$container" sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d aisl_dev' < "$here/aisl-dev-migration-role.sql"
# Verify both creating new migration objects and altering an existing object.
# Roll back this probe so no schema/data change is left behind.
docker exec -i "$container" sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d aisl_dev' <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL ROLE aisl_app;
CREATE TABLE public.infra_migration_permission_probe (id integer);
ALTER TABLE public.django_migrations SET (autovacuum_enabled = true);
ROLLBACK;
SQL
printf 'Verified dev migration permissions; private rollback snapshot: %s\n' "$backup"
printf 'Membership rollback (only if not previously present): REVOKE aisl_dev FROM aisl_app;\n'
