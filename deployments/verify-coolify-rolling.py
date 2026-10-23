#!/usr/bin/env python3
"""Measure one native rolling redeploy; retain public probes and lifecycle proof.

Requires explicit --deploy. Writes only sanitized evidence, never API log bodies,
container environments or origin credentials. Public URL must exercise readiness.
"""
import argparse
import collections
import datetime
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import threading
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rolling', HERE / 'coolify-rolling-web.py')
rolling = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rolling)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def ssh(host, command):
    return subprocess.check_output(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                                    host, command], text=True, timeout=40)


def snapshot(app, config):
    ids = ssh(app['ssh_host'], 'sudo docker ps -q --filter label=dtc.rolling-web.application=' + app['app_uuid']).split()
    if not ids:
        raise ValueError('No running public replica')
    containers = json.loads(ssh(app['ssh_host'], 'sudo docker inspect ' + shlex.join(ids)))
    result = []
    for container in containers:
        mounts = {m['Destination']: m['Source'] for m in container['Mounts']}
        output = ssh(app['ssh_host'], 'sudo docker exec ' + shlex.quote(container['Id']) +
                     ' sha256sum ' + shlex.join(rolling.ASSET_TARGETS.values()))
        hashes = {line.split()[1]: line.split()[0] for line in output.splitlines()}
        for filename, target in rolling.ASSET_TARGETS.items():
            if (hashes.get(target) != config['assets'][filename] or
                    mounts.get(target) != rolling.asset_path(app['app_uuid'], filename, config['assets'][filename])):
                raise ValueError('Running helper does not match versioned manifest')
        result.append({'id': container['Id'], 'name': container['Name'],
                       'health': container['State'].get('Health', {}).get('Status'),
                       'hashes': hashes, 'mounts': {target: mounts[target] for target in hashes}})
    return result


def probe(url, stop, rows, file):
    with file.open('x', buffering=1) as output:
        while not stop.is_set():
            started = time.monotonic()
            row = {'time': now()}
            try:
                request = urllib.request.Request(url + '?rolling_verify=' + str(time.time_ns()),
                    headers={'Cache-Control': 'no-cache', 'User-Agent': 'rolling-acceptance-probe'})
                with urllib.request.urlopen(request, timeout=5) as response:
                    row['status'] = response.status
                    response.read()
            except urllib.error.HTTPError as error:
                row['status'] = error.code
            except Exception as error:
                row['status'] = type(error).__name__
            row['ms'] = round((time.monotonic() - started) * 1000)
            rows.append(row)
            output.write(json.dumps(row) + '\n')
            stop.wait(max(0, .3 - (time.monotonic() - started)))


def lifecycle(events, old, new):
    def first(identity, action):
        values = [e['timeNano'] for e in events if e.get('id') == identity and e.get('Action') == action]
        if not values:
            raise ValueError('Missing lifecycle event: ' + action)
        return min(values)
    stamps = {'new_started': first(new, 'start'), 'new_healthy': first(new, 'health_status: healthy'),
              'old_drained': first(old, 'exec_start: python /opt/rolling-readiness.py drain'),
              'old_killed': first(old, 'kill')}
    ordered = list(stamps.values())
    if ordered != sorted(set(ordered)) or (stamps['old_killed'] - stamps['old_drained']) / 1e9 < 6:
        raise ValueError('Replacement was not healthy before drain and six-second withdrawal')
    return {key: datetime.datetime.fromtimestamp(value / 1e9, datetime.timezone.utc).isoformat()
            for key, value in stamps.items()}


def collect_events(process, events, file):
    # Stream from before deployment: Docker retains only a bounded history,
    # which frequent health exec events can overwrite during a long build.
    with file.open('x', buffering=1) as output:
        for line in process.stdout:
            event = json.loads(line)
            safe = {key: event.get(key) for key in ('id', 'Action', 'timeNano')}
            events.append(safe)
            output.write(json.dumps(safe) + '\n')


def verify(args):
    config = json.loads(args.config.read_text())
    app = next(a for a in config['applications'] if a['name'] == args.app)
    api = rolling.API(config['base'], Path(config['token_file']).read_text().strip())
    path = '/api/v1/applications/' + app['app_uuid']
    rolling.verify_control_plane(config)
    rolling.verify_host_assets(config)
    rolling.rolling_guard(api('GET', path), ('dockerfile',) if app.get('rollout_mode') == 'git-commit' else ('dockerimage',))
    rolling.verify_asset_bindings({**app, 'asset_hashes': config['assets']}, api, path)
    queues = api('GET', '/api/v1/deployments/applications/' + app['app_uuid'])['deployments']
    if any(d['status'] in ('queued', 'in_progress') for d in queues):
        raise ValueError('Application has an active deployment')
    before = snapshot(app, config)
    if len(before) != 1 or before[0]['health'] != 'healthy':
        raise ValueError('Expected one healthy baseline replica')
    args.output.mkdir(parents=True, exist_ok=False)
    result = {'app': app['name'], 'started': now(), 'before': before}
    (args.output / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
    events = []
    command = ('sudo docker events --since ' + shlex.quote(result['started']) +
               ' --filter type=container --filter label=dtc.rolling-web.application=' +
               app['app_uuid'] + " --format '{{json .}}'")
    event_process = subprocess.Popen(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                                     app['ssh_host'], command], stdout=subprocess.PIPE, text=True)
    event_worker = threading.Thread(target=collect_events,
        args=(event_process, events, args.output / 'events.jsonl'), daemon=True)
    event_worker.start()
    rows, stop = [], threading.Event()
    worker = threading.Thread(target=probe, args=(args.url, stop, rows, args.output / 'probes.jsonl'))
    worker.start()
    try:
        time.sleep(10)
        if len(rows) < 10 or any(row['status'] != 200 for row in rows):
            raise ValueError('Public readiness baseline failed')
        deployment = api('POST', '/api/v1/deploy?uuid=' + app['app_uuid'])['deployments'][0]['deployment_uuid']
        result['deployment_uuid'] = deployment
        (args.output / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Requested rolling deployment ' + deployment, flush=True)
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            current = api('GET', '/api/v1/deployments/' + deployment)
            if current['status'] not in ('queued', 'in_progress'):
                result['deployment_status'] = current['status']
                if current['status'] != 'finished':
                    raise ValueError('Deployment did not finish successfully')
                break
            time.sleep(5)
        else:
            raise TimeoutError('Deployment exceeded observation deadline')
        after = snapshot(app, config)
        result['after'] = after
        if len(after) != 1 or after[0]['health'] != 'healthy' or after[0]['id'] == before[0]['id']:
            raise ValueError('Expected a different healthy replacement')
        print('Replacement healthy; observing public readiness for another 60 seconds.', flush=True)
        time.sleep(60)
        result['finished'] = now()
        if not event_worker.is_alive() or event_process.poll() is not None:
            raise ValueError('Lifecycle collector exited before observation completed')
        result['lifecycle'] = lifecycle(events, before[0]['id'], after[0]['id'])
    except Exception as error:
        result['error'] = type(error).__name__ + ': ' + str(error) if isinstance(error, (ValueError, TimeoutError)) else type(error).__name__
    finally:
        stop.set()
        worker.join()
        event_process.terminate()
        try:
            event_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            event_process.kill()
            event_process.wait()
        event_worker.join(timeout=5)
        event_process.stdout.close()
    result['public_probes'] = {'samples': len(rows), 'statuses': dict(collections.Counter(str(row['status']) for row in rows)),
                               'max_ms': max((row['ms'] for row in rows), default=0)}
    result['accepted'] = not result.get('error') and bool(rows) and all(row['status'] == 200 for row in rows)
    (args.output / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=HERE / 'coolify-rolling-web.json')
    parser.add_argument('--app', required=True, choices=('website', 'cmp', 'aishl'))
    parser.add_argument('--url', required=True, help='Public readiness endpoint without a query string')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    parser.add_argument('--deploy', action='store_true', required=True)
    args = parser.parse_args()
    if not args.url.startswith('https://') or '?' in args.url or '#' in args.url:
        parser.error('Use a public HTTPS readiness URL without query or fragment')
    raise SystemExit(verify(args))
