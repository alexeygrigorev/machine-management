#!/usr/bin/env python3
"""Install the version-checked, persistent Coolify pre-stop hook from Hetzner.

Default is read-only. --apply recreates only the Coolify control plane;
running public applications, databases and the proxy are not recreated.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys

import yaml

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('drain_patch', HERE / 'patch-coolify-drain.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
PATCHED = '5f0ec6723e21408c760c6d307e5d5afc56cd34e131010dc204c25eb3eca030a0'
JOB = '/var/www/html/app/Jobs/ApplicationDeploymentJob.php'
MOUNT = '/data/coolify/custom/rolling/ApplicationDeploymentJob.php'
PROD = '/data/coolify/source/docker-compose.prod.yml'


def ssh(host, command, data=None):
    return subprocess.run(['ssh', '-F', '/home/alexey/.ssh/config',
        '-i', '/home/alexey/.ssh/id_contabo', '-o', 'BatchMode=yes', host, command],
        input=data, capture_output=True, text=True, check=True, timeout=120).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--primary', default='contabo-a')
    parser.add_argument('--config', type=Path, default=HERE / 'coolify-rolling-web.json')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    original = ssh(args.primary, 'sudo docker exec coolify cat ' + JOB)
    digest = hashlib.sha256(original.encode()).hexdigest()
    if digest not in (patcher.EXPECTED, PATCHED):
        raise ValueError('Untested Coolify job version; refusing control-plane changes')
    patched = original if digest == PATCHED else patcher.patch(original.encode()).decode()
    # Lint in the currently running, version-matched PHP runtime before writes.
    ssh(args.primary, 'sudo docker exec -i coolify php -l', patched)
    raw = ssh(args.primary, 'sudo cat ' + PROD)
    doc = yaml.safe_load(raw)
    image = json.loads(ssh(args.primary, "sudo docker inspect coolify --format '{{json .Config.Image}}'"))
    if not image.endswith('/coollabsio/coolify:4.4.7'):
        raise ValueError('Control-plane image must be the tested pinned 4.4.7 release')
    project = ssh(args.primary, "sudo docker inspect coolify --format '{{index .Config.Labels \"com.docker.compose.project\"}}'").strip()
    service = doc['services']['coolify']
    volumes = service.setdefault('volumes', [])
    bind = MOUNT + ':' + JOB + ':ro'
    if bind not in volumes:
        if any(JOB in str(v) for v in volumes):
            raise ValueError('Conflicting deployment job mount')
        volumes.append(bind)
    service['image'] = image
    updated = yaml.safe_dump(doc, sort_keys=False)
    if not args.apply:
        print('Version and syntax verified. Plan: install host drain hook and persistent control-plane job mount.')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = Path('/home/alexey/tmp') / ('coolify-drain-control-backup-' + stamp)
    backup.mkdir(mode=0o700)
    for name, value in [('ApplicationDeploymentJob.php', original), ('docker-compose.prod.yml', raw)]:
        file = backup / name
        file.write_text(value)
        file.chmod(0o600)
    hosts = sorted({c['ssh_host'] for c in config['applications']})
    for host in hosts:
        ssh(host, 'sudo tee /usr/local/sbin/coolify-web-drain.py >/dev/null', (HERE / 'coolify-web-drain.py').read_text())
        ssh(host, 'sudo chmod 755 /usr/local/sbin/coolify-web-drain.py')
    ssh(args.primary, 'sudo mkdir -p /data/coolify/custom/rolling')
    ssh(args.primary, 'sudo tee ' + MOUNT + ' >/dev/null', patched)
    ssh(args.primary, 'sudo chmod 644 ' + MOUNT)
    if updated != raw:
        ssh(args.primary, 'sudo tee ' + PROD + '.rolling.tmp >/dev/null', updated)
        ssh(args.primary, 'sudo chmod 600 ' + PROD + '.rolling.tmp && sudo mv ' + PROD + '.rolling.tmp ' + PROD)
    ssh(args.primary, shlex.join(['sudo', 'docker', 'compose', '--project-directory', '/data/coolify/source',
        '--project-name', project, '-f', '/data/coolify/source/docker-compose.yml', '-f', PROD,
        'up', '-d', '--no-deps', 'coolify']))
    print('Installed persistent drain hook; control-plane image pinned to tested version. Public containers preserved.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Drain installation failed (' + type(error).__name__ + '); inspect private state.', file=sys.stderr)
        sys.exit(1)
