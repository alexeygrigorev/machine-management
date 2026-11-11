#!/usr/bin/env python3
"""Persist and apply the audited PostgreSQL limits without restarting databases."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request

DATABASES = ('mqimefrti7ratmaliirnikov', 'ekm57uezdngrrscn0aqzidr8')
LIMIT = 8 * 1024**3
FIELDS = {'limits_memory': '8g', 'limits_memory_swap': '8g', 'limits_cpu_shares': 4096}


def memory_bytes(raw):
    match = re.fullmatch(r'([0-9.]+)\s*(B|KiB|MiB|GiB|TiB)', raw.strip())
    if not match:
        raise ValueError('Unrecognized Docker memory measurement')
    return float(match[1]) * 1024 ** ('B', 'KiB', 'MiB', 'GiB', 'TiB').index(match[2])


def validate(database, container, usage):
    if database.get('database_type') != 'standalone-postgresql' or database.get('uuid') not in DATABASES:
        raise ValueError('Unexpected database identity/type')
    if container['Name'] != '/' + database['uuid'] or not container['Config']['Image'].startswith('postgres:16'):
        raise ValueError('Unexpected runtime identity/image')
    if not container['State']['Running'] or container['State'].get('Health', {}).get('Status') != 'healthy':
        raise ValueError('Database is not healthy; do not change budgets')
    if usage > LIMIT / 2 or container['HostConfig']['Memory'] > LIMIT:
        raise ValueError('Insufficient memory headroom or existing higher limit; review sizing')


def remote(*arguments):
    return subprocess.check_output(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                                    'contabo-b', 'sudo', 'docker', *arguments], text=True, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--backup-dir', type=Path, required=True)
    args = parser.parse_args()
    token = args.token_file.read_text().strip()

    def api(identity, patch=None):
        request = urllib.request.Request('http://127.0.0.1:18000/api/v1/databases/' + identity,
            data=json.dumps(patch).encode() if patch is not None else None,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
            method='PATCH' if patch is not None else 'GET')
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    for identity in DATABASES:
        database = api(identity)
        container = json.loads(remote('inspect', identity))[0]
        usage = memory_bytes(remote('stats', '--no-stream', '--format', "'{{.MemUsage}}'", identity).split('/')[0])
        validate(database, container, usage)
        before_api = {key: database[key] for key in FIELDS}
        before_runtime = {key: container['HostConfig'][key] for key in ('Memory', 'MemorySwap', 'CpuShares')}
        print(f'{identity}: healthy, working memory {usage / 1024**3:.2f}GiB; target 8GiB / CPU weight 4096', flush=True)
        if not args.apply:
            continue
        args.backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        snapshot = args.backup_dir / f'{identity}-{stamp}.json'
        fd = os.open(snapshot, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'identity': identity, 'api': before_api, 'runtime': before_runtime}, stream)
        try:
            api(identity, {**FIELDS, 'instant_deploy': False})
            if any(api(identity).get(key) != value for key, value in FIELDS.items()):
                raise RuntimeError('Persisted database limits did not match')
            remote('update', '--memory', '8g', '--memory-swap', '8g', '--cpu-shares', '4096', identity)
            current = json.loads(remote('inspect', identity))[0]
            if any(current['HostConfig'][key] != value for key, value in
                   {'Memory': LIMIT, 'MemorySwap': LIMIT, 'CpuShares': 4096}.items()):
                raise RuntimeError('Runtime limits did not match')
            if current['State']['StartedAt'] != container['State']['StartedAt'] or current['RestartCount'] != container['RestartCount']:
                raise RuntimeError('Database lifecycle changed during apply')
            validate(api(identity), current, usage)
        except Exception:
            # Restore exactly the budgets touched here. Never restart a DB.
            api(identity, {**before_api, 'instant_deploy': False})
            remote('update', '--memory', str(before_runtime['Memory']), '--memory-swap',
                   str(before_runtime['MemorySwap'] or -1), '--cpu-shares', str(before_runtime['CpuShares'] or 1024), identity)
            raise
        print(f'{identity}: persisted and live verified; no restart; rollback snapshot {snapshot}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # HTTP bodies, commands and environment can carry secrets; print type only.
        raise SystemExit('PostgreSQL budget update FAILED: ' + type(error).__name__)
