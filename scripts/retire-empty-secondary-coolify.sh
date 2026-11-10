#!/usr/bin/env bash
# F11: retire only the proven-empty, unmanaged secondary control plane.
# Default read-only; databases/volumes/application containers are preserved.
set -euo pipefail
mode="${1:---plan}"
[[ "$mode" == --plan || "$mode" == --apply ]]
ssh -o BatchMode=yes contabo-a 'curl -fsS --max-time 10 http://127.0.0.1:8000/api/health >/dev/null'
ssh -o BatchMode=yes contabo-b sudo bash -s -- "$mode" <<'SH'
set -euo pipefail
mode="$1"
for name in coolify coolify-db coolify-redis; do
  managed=$(docker inspect "$name" --format '{{index .Config.Labels "coolify.managed"}}')
  [[ -z "$managed" ]] || { echo "Refusing Coolify-managed container: $name"; exit 1; }
done
php=$(cat <<'PHP'
$rows = Illuminate\Support\Facades\DB::select("select tablename from pg_tables where schemaname='public' and (tablename in ('applications','services') or (tablename like 'standalone_%' and tablename <> 'standalone_dockers'))");
$counts = []; foreach ($rows as $row) { $counts[$row->tablename] = Illuminate\Support\Facades\DB::table($row->tablename)->count(); }
echo json_encode($counts);
PHP
)
counts=$(docker exec coolify php artisan tinker --execute="$php")
printf '%s' "$counts" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "applications" in d and "services" in d and len(d)>=3 and all(v==0 for v in d.values()), "secondary owns resources"; print("All secondary app/service/database tables empty:", len(d))'
test -s /etc/coolify-cp-backup.pass
command -v gpg >/dev/null
[[ "$mode" == --apply ]] || { echo 'Plan: encrypted secondary metadata/database backup, then stop/remove only coolify,coolify-db,coolify-redis; retain volumes.'; exit; }
umask 077
scratch=''
trap '[[ -z "$scratch" ]] || rm -rf -- "$scratch"' EXIT
scratch=$(mktemp -d /tmp/fable-secondary-backup-XXXXXX)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
destination=/var/backups/fable-secondary-coolify-$stamp.tar.gz.gpg
docker inspect coolify coolify-db coolify-redis > "$scratch/containers.json"
printf '%s\n' "$counts" > "$scratch/resource-counts.json"
docker exec coolify-db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "${POSTGRES_DB:-coolify}"' > "$scratch/coolify.sql"
test -s "$scratch/coolify.sql"
tar -C /data/coolify -czf "$scratch/source.tar.gz" source
tar -C "$scratch" -czf - containers.json resource-counts.json coolify.sql source.tar.gz \
  | gpg --batch --yes --pinentry-mode loopback --passphrase-file /etc/coolify-cp-backup.pass --symmetric --cipher-algo AES256 -o "$destination"
gpg --batch --pinentry-mode loopback --passphrase-file /etc/coolify-cp-backup.pass --decrypt "$destination" 2>/dev/null | tar -tzf - >/dev/null
sha256sum "$destination"
others=$(docker ps --format '{{.ID}} {{.Names}}' | awk '$2!="coolify" && $2!="coolify-db" && $2!="coolify-redis" {print $1}')
docker stop -t 60 coolify coolify-db coolify-redis >/dev/null
docker rm coolify coolify-db coolify-redis >/dev/null
for id in $others; do
  [[ "$(docker inspect "$id" --format '{{.State.Running}}')" == true ]] || { echo "Unrelated container changed state: $id"; exit 1; }
done
echo 'Secondary retired; every other running container preserved, all volumes retained. Primary control plane owns this server.'
SH
