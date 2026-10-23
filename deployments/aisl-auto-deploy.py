#!/usr/bin/env python3
"""Poll AISHL's pinned GHCR release. Default: read-only; --apply permits changes.

Requires PyYAML. Read credentials from private files; never print API bodies.
"""
import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
import urllib.request

import yaml

UUID = 'mekt9kz74fvbixla6olinuma'
IMAGE = 'ghcr.io/ai-shipping-labs/website'
DATED_TAG = re.compile(r'\d{8}-\d{6}-[a-f0-9]{7,40}\Z')


def canonical(image):
    """Accept Coolify's optional GHCR prefix for this repository only."""
    if isinstance(image, str) and image.startswith('ai-shipping-labs/website:'):
        return 'ghcr.io/' + image
    return image


def plan(service, tag):
    if not DATED_TAG.fullmatch(tag):
        raise ValueError('Expected an immutable dated release tag')
    raw = service['docker_compose_raw']
    compose = yaml.safe_load(raw)
    services = compose['services']
    selected = {name: item for name, item in services.items()
                if canonical(item.get('image', '')).startswith(IMAGE + ':')}
    if 'web' not in selected or ('worker' in services and 'worker' not in selected):
        raise ValueError('AISHL web/worker image ownership is inconsistent')
    target = IMAGE + ':' + tag
    changed_images = any(canonical(item['image']) != target for item in selected.values())
    # Check all matching runtime applications, independent of API array order.
    apps = service.get('applications', [])
    runtime = {a['name']: canonical(a.get('image', '')) for a in apps if a.get('name') in selected}
    if set(runtime) != set(selected):
        raise ValueError('Runtime application inventory does not match compose')
    changed_images |= any(image != target for image in runtime.values())
    changed_policy = any(item.get('pull_policy') != 'missing' for item in selected.values())
    if not changed_images and not changed_policy:
        return raw, False
    for item in selected.values():
        item['image'] = target
        item['pull_policy'] = 'missing'
    return yaml.safe_dump(compose, sort_keys=False), changed_images


def latest_tag(versions):
    candidates = [(v['created_at'], tag) for v in versions
                  for tag in v.get('metadata', {}).get('container', {}).get('tags', [])
                  if DATED_TAG.fullmatch(tag)]
    if not candidates:
        raise ValueError('No immutable dated GHCR release found')
    return max(candidates)[1]


def reconcile(call, tag, apply=False, backup=None):
    path = '/api/v1/services/' + UUID
    service = call('GET', path)
    updated, deploy = plan(service, tag)
    if updated == service['docker_compose_raw'] and not deploy:
        print('In sync: web/worker images match the pinned release; no writes or deployment.')
        return 'in-sync'
    if not apply:
        print('Read-only plan: update pinned images/pull policy; deployment required: ' + str(deploy))
        return 'planned'
    if backup is None:
        raise ValueError('Private rollback directory required')
    backup.mkdir(mode=0o700, parents=True, exist_ok=True)
    name = dt.datetime.now(dt.timezone.utc).strftime('compose-%Y%m%dT%H%M%S%f.json')
    with open(backup / name, 'x', opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(service, stream)
    if call('GET', path)['docker_compose_raw'] != service['docker_compose_raw']:
        raise ValueError('Concurrent compose edit; refusing to overwrite')
    call('PATCH', path, {'docker_compose_raw': base64.b64encode(updated.encode()).decode()})
    persisted = call('GET', path)
    if yaml.safe_load(persisted['docker_compose_raw']) != yaml.safe_load(updated):
        raise ValueError('Compose persistence verification failed')
    if deploy:
        call('POST', '/api/v1/deploy?uuid=' + UUID)
        print('Pinned all AISHL application images; one deployment requested.')
        return 'deployed'
    print('Pinned pull policy persisted; no deployment needed.')
    return 'policy-updated'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    home = Path.home()
    base = os.environ.get('COOLIFY_URL', 'http://169.58.119.163:8000').rstrip('/')
    token = Path(os.environ.get('COOLIFY_TOKEN_FILE', str(home / 'tmp/secrets/coolify-api-169.58.119.163.token'))).read_text().strip()
    pat = Path(os.environ.get('GH_PAT_FILE', str(home / 'tmp/secrets/coolify-ghcr-read.pat'))).read_text().strip()

    def request(url, credential, method='GET', payload=None):
        req = urllib.request.Request(url, method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + credential, 'Accept': 'application/json',
                     'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=40) as response:
            data = response.read()
            return json.loads(data) if data else {}

    versions = request('https://api.github.com/orgs/AI-Shipping-Labs/packages/container/website/versions?per_page=100', pat)
    tag = latest_tag(versions)
    def call(method, path, payload=None):
        return request(base + path, token, method, payload)
    reconcile(call, tag, args.apply, home / '.local/state/aisl-auto-deploy/rollback')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # API errors, compose and environment values must not enter cron logs.
        print('AISHL poller failed (' + type(error).__name__ + '); no automatic retry in this run.', file=sys.stderr)
        sys.exit(1)
