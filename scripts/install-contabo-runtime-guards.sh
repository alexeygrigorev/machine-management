#!/usr/bin/env bash
# Deliberate host runtime controls; no Docker restart or reboot.
set -euo pipefail
host="${1:?usage: install-contabo-runtime-guards.sh contabo-a|contabo-b}"
[[ "$host" == contabo-a || "$host" == contabo-b ]]
ssh -o BatchMode=yes "$host" sudo bash -s <<'SH'
set -euo pipefail
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/var/backups/fable-runtime-$stamp
install -d -m 0700 "$backup"
[[ ! -f /etc/docker/daemon.json ]] || cp -p /etc/docker/daemon.json "$backup/daemon.json"
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('/etc/docker/daemon.json')
config = json.loads(p.read_text()) if p.exists() else {}
config['live-restore'] = True
p.write_text(json.dumps(config, indent=2) + '\n')
PY
dockerd --validate --config-file=/etc/docker/daemon.json
systemctl reload docker
docker info --format 'live-restore={{.LiveRestoreEnabled}}'
apt-mark showhold > "$backup/apt-holds.txt"
apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Preserve current CPU weights for rollback, and prefer the serving/data path.
docker inspect $(docker ps -q) > "$backup/containers.json"
python3 - "$backup/containers.json" <<'PY'
import json,subprocess,sys
for c in json.load(open(sys.argv[1])):
    labels=c['Config'].get('Labels') or {}
    if (c['Name']=='/coolify-proxy' or labels.get('dtc.rolling-web.application')
            or c['Config']['Image'].startswith('postgres:')):
        subprocess.run(['docker','update','--cpu-shares','4096',c['Id']],check=True,stdout=subprocess.DEVNULL)
        print('CPU weight4096:', c['Name'])
PY
# Only permissions change; never read keys or remove undocumented access.
find /etc/wireguard -maxdepth 1 -type f -name '*.key' -exec chmod 600 {} +
echo "Runtime rollback metadata: $backup"
SH
