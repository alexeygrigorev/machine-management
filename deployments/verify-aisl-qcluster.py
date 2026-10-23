#!/usr/bin/env python3
"""Verify the live worker, key/DB parity, and recent successful execution.

Only sanitized operational evidence is printed. --min-uptime 900 enforces
15-minute stability; compare ID and StartedAt with the first observation too.
"""
import argparse
import datetime as dt
import ipaddress
import json
import subprocess
from pathlib import Path
from urllib.parse import urlparse

UUID = 'mekt9kz74fvbixla6olinuma'


def remote(*args, input=None):
    import shlex
    return subprocess.run(['ssh', 'contabo-b', shlex.join(args)], input=input,
                          text=True, capture_output=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--min-uptime', type=int, default=900)
    parser.add_argument('--baseline', type=Path, help='Earlier JSON evidence; require unchanged ID and StartedAt')
    args = parser.parse_args()
    containers = json.loads(remote('sudo', 'docker', 'inspect', 'web-' + UUID, 'worker-' + UUID))
    web, worker = containers
    envs = [dict(x.split('=', 1) for x in c['Config']['Env']) for c in containers]
    for key in ('SECRET_KEY', 'DATABASE_URL'):
        assert envs[0].get(key) and envs[0][key] == envs[1].get(key), key + ' parity failed'
    host = urlparse(envs[1]['DATABASE_URL']).hostname
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise AssertionError('Database must use DNS, not a pinned IP')
    assert worker['Config']['Image'] == web['Config']['Image'], 'Image mismatch'
    assert worker['HostConfig']['RestartPolicy']['Name'] == 'unless-stopped'
    assert not worker['HostConfig'].get('PortBindings'), 'Worker publishes ports'
    assert envs[1]['BOOT_MODE'] == 'worker' and envs[1]['RUN_MIGRATIONS'] == 'false'
    started = worker['State']['StartedAt']
    now = dt.datetime.now(dt.timezone.utc)
    age = (now - dt.datetime.fromisoformat(started.replace('Z', '+00:00'))).total_seconds()
    evidence = {'observed_at': now.isoformat(), 'worker_id': worker['Id'],
                'worker_started_at': started, 'uptime_seconds': round(age),
                'restarts': worker['RestartCount'], 'status': worker['State']['Status'],
                'health': worker['State'].get('Health', {}).get('Status'),
                'web_health': web['State'].get('Health', {}).get('Status'),
                'image': worker['Config']['Image'], 'database_host': host,
                'shared_secret_key': True, 'shared_database': True}
    # SQL uses only operational columns; task args/results can contain private data.
    sql = """SELECT json_build_object(
      'observed_at', now(),
      'queued', (SELECT count(*) FROM django_q_ormq),
      'schedules', (SELECT count(*) FROM django_q_schedule),
      'latest_success', (SELECT max(stopped) FROM django_q_task WHERE success),
      'successes_after_start', (SELECT count(*) FROM django_q_task WHERE success AND stopped >= '%s'::timestamptz),
      'failures_after_start', (SELECT count(*) FROM django_q_task WHERE NOT success AND stopped >= '%s'::timestamptz),
      'successes_last_5m', (SELECT count(*) FROM django_q_task WHERE success AND stopped > now()-interval '5 minutes')
    );""" % (started, started)
    evidence['django_q'] = json.loads(remote('sudo', 'docker', 'exec', '-i',
        'ekm57uezdngrrscn0aqzidr8', 'sh', '-c', 'psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d aisl', input=sql))
    print(json.dumps(evidence, indent=2))
    if args.baseline:
        previous = json.loads(args.baseline.read_text())
        for key in ('worker_id', 'worker_started_at'):
            assert evidence[key] == previous[key], 'Worker changed since baseline: ' + key
    assert worker['State']['Running'] and worker['RestartCount'] == 0
    assert evidence['health'] == 'healthy' and evidence['web_health'] == 'healthy'
    assert age >= args.min_uptime, 'Minimum uptime not reached'
    assert evidence['django_q']['successes_after_start'] > 0
    assert evidence['django_q']['successes_last_5m'] > 0, 'No recent successes'


if __name__ == '__main__':
    main()
