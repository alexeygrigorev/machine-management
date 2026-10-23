#!/usr/bin/env python3
"""Add AISHL's worker to its existing Coolify service; never change web or secrets.

Requires PyYAML. Default is a read-only plan; --apply saves and deploys.
Private rollback snapshots are saved outside the repository.
"""
import argparse
import base64
import copy
import json
import os
from pathlib import Path
import urllib.request

import yaml

UUID = 'mekt9kz74fvbixla6olinuma'
HEALTH = (
    'import os,socket; os.environ.setdefault("DJANGO_SETTINGS_MODULE","website.settings"); '
    'import django; django.setup(); from django_q.status import Stat; '
    'from django.utils import timezone; '
    'assert any(s.host == socket.gethostname() and s.status in ("Idle", "Working") '
    'and (timezone.now()-s.timestamp).total_seconds() < 10 for s in Stat.get_all())'
)


def add_worker(raw):
    compose = yaml.safe_load(raw)
    web = compose['services']['web']
    worker = {
        'image': web['image'],
        'pull_policy': web.get('pull_policy', 'missing'),
        'restart': 'unless-stopped',
        'environment': copy.deepcopy(web.get('environment', {})),
        'healthcheck': {
            'test': ['CMD', '/app/.venv/bin/python', '-c', HEALTH],
            'interval': '30s', 'timeout': '15s', 'retries': 5,
            'start_period': '120s',
        },
        'stop_grace_period': '330s',
    }
    env = worker['environment']
    if isinstance(env, list):
        env = dict(item.split('=', 1) if '=' in item else (item, None) for item in env)
        worker['environment'] = env
    for key in ('GUNICORN_WORKERS', 'GUNICORN_THREADS'):
        env.pop(key, None)
    env.update(BOOT_MODE='worker', RUN_MIGRATIONS='false', Q_WORKERS='2')
    # Preserve explicit runtime dependencies if the service uses them.
    for key in ('env_file', 'networks', 'volumes'):
        if key in web:
            worker[key] = copy.deepcopy(web[key])
    existing = compose['services'].get('worker')
    if existing is not None and existing != worker:
        raise ValueError('An existing worker differs; inspect before changing it')
    compose['services']['worker'] = worker
    return yaml.safe_dump(compose, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    base = os.environ.get('COOLIFY_URL', 'http://169.58.119.163:8000').rstrip('/')
    token = Path(os.environ.get('COOLIFY_TOKEN_FILE', str(Path.home() / '.secrets/coolify-api-169.58.119.163.token'))).read_text().strip()

    def call(method, path, payload=None):
        req = urllib.request.Request(base + path, method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)

    path = '/api/v1/services/' + UUID
    service = call('GET', path)
    raw = service['docker_compose_raw']
    updated = add_worker(raw)
    print('Worker plan: same web image; BOOT_MODE=worker; no migrations; two processes; shared Coolify env; no published ports.')
    if yaml.safe_load(raw) == yaml.safe_load(updated):
        print('Worker already configured; no deploy requested.')
        return
    if not args.apply:
        print('Read-only plan. Use --apply to save and deploy.')
        return
    backup = Path.home() / 'tmp/aisl-qcluster-t1218u'
    backup.mkdir(mode=0o700, parents=True, exist_ok=True)
    snapshot = backup / 'compose-before-apply.json'
    # Refuse to overwrite original rollback evidence.
    with open(snapshot, 'x', opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(service, stream)
    # Avoid overwriting a concurrent Coolify edit between plan and mutation.
    if call('GET', path)['docker_compose_raw'] != raw:
        raise RuntimeError('Compose changed during planning; inspect and retry')
    call('PATCH', path, {'docker_compose_raw': base64.b64encode(updated.encode()).decode()})
    persisted = call('GET', path)['docker_compose_raw']
    assert yaml.safe_load(persisted) == yaml.safe_load(updated), 'Compose did not persist'
    call('POST', '/api/v1/deploy?uuid=' + UUID + '&force=true')
    print('Worker saved in Coolify and service deployment requested.')


if __name__ == '__main__':
    main()
