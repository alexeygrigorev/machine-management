#!/usr/bin/env python3
"""Follow promoted Compose web releases with native Coolify rolling applications.

No secret values or API bodies are logged. See coolify-rolling-web.md.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.request


def labels_for_web(source_labels, source_uuid, app_uuid, path):
    """Independent router identities; preserve HTTPS and origin allow/deny priority."""
    labels = {}
    for line in source_labels:
        key, _, value = line.partition('=')
        if key.startswith('traefik.'):
            labels[key.replace(source_uuid, app_uuid)] = value.replace(source_uuid, app_uuid)
    labels['traefik.docker.network'] = 'coolify'
    labels['traefik.http.middlewares.rolling-retry.retry.attempts'] = '3'
    labels['traefik.http.middlewares.rolling-retry.retry.initialinterval'] = '100ms'
    for key in list(labels):
        if key.startswith('traefik.http.routers.') and key.endswith('.rule'):
            prefix = key.removesuffix('.rule')
            labels[prefix + '.priority'] = '100'
            middlewares = labels.get(prefix + '.middlewares', '')
            if 'redirect-to-https' not in middlewares:
                labels[prefix + '.middlewares'] = ','.join(filter(None, [middlewares, 'rolling-retry']))
        if key.endswith('.loadbalancer.server.port'):
            prefix = key.removesuffix('.server.port')
            labels[prefix + '.healthcheck.path'] = path
            labels[prefix + '.healthcheck.hostname'] = 'localhost'
            labels[prefix + '.healthcheck.interval'] = '2s'
            labels[prefix + '.healthcheck.timeout'] = '1s'
            labels[prefix + '.serverstransport'] = 'rolling-web@file'
    return '\n'.join(k + '=' + str(v) for k, v in sorted(labels.items()))


def rolling_guard(app):
    settings = app.get('settings') or {}
    labels = base64.b64decode(app.get('custom_labels') or '').decode()
    if (app.get('build_pack') != 'dockerimage' or app.get('ports_mappings')
            or settings.get('is_consistent_container_name_enabled')
            or settings.get('custom_internal_name')
            or re.search(r'--(?:ip6?|name|publish)(?:[=\s]|$)|(?:^|\s)-p(?:\s|$)', app.get('custom_docker_run_options') or '')
            or not app.get('health_check_enabled')
            or '.loadbalancer.healthcheck.path=' not in labels):
        raise ValueError('Native application is not eligible for health-gated rolling updates')


def source_state(config):
    uuid = config['source_uuid']
    if not re.fullmatch('[a-z0-9]+', uuid):
        raise ValueError('Invalid source identifier')
    cmd = ('sudo docker inspect ' + shlex.quote('web-' + uuid))
    result = subprocess.run(['ssh', '-F', config.get('ssh_config', '/home/alexey/.ssh/config'),
        '-i', config.get('ssh_identity', '/home/alexey/.ssh/id_contabo'),
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', config['ssh_host'], cmd],
        check=True, capture_output=True, text=True, timeout=30)
    container = json.loads(result.stdout)[0]
    if container['State'].get('Health', {}).get('Status') != 'healthy':
        raise ValueError('Source web is not healthy; keeping public application')
    env = dict(item.split('=', 1) for item in container['Config']['Env'])
    # Deployment metadata belongs to the new application, not the source stack.
    env = {k: v for k, v in env.items() if not k.startswith(('COOLIFY_', 'SERVICE_'))}
    env.update(config.get('environment', {}))
    return container['Config']['Image'], env


def reconcile(config, call, state=source_state, apply=False):
    image, env = state(config)
    if not re.fullmatch(re.escape(config['image']) + r':\d{8}-\d{6}-[a-f0-9]{7,40}', image):
        raise ValueError('Source image is outside the promoted immutable repository')
    app_path = '/api/v1/applications/' + config['app_uuid']
    app = call('GET', app_path)
    rolling_guard(app)
    queues = call('GET', '/api/v1/deployments/applications/' + config['app_uuid'])
    deployments = queues.get('deployments', []) if isinstance(queues, dict) else queues
    if any(d.get('status') in ('queued', 'in_progress') for d in deployments):
        return 'busy'
    current_env = {e['key']: e.get('value', '') for e in call('GET', app_path + '/envs')
                   if not e.get('is_preview')}
    changed_env = {k: v for k, v in env.items() if current_env.get(k) != v}
    tag = image.rsplit(':', 1)[1]
    changed_image = app.get('docker_registry_image_tag') != tag or app.get('docker_registry_image_name') != config['image']
    # Reconcile failed or interrupted deployments too, even when desired metadata
    # already has the target tag. Never let a failed rollout look converged.
    last = deployments[0] if deployments else {}
    needs_retry = last.get('status') in ('failed', 'cancelled', 'cancelled-by-user')
    if not changed_env and not changed_image and not needs_retry:
        return 'in-sync'
    if not apply:
        return 'planned'
    if changed_env:
        call('PATCH', app_path + '/envs/bulk', {'data': [
            {'key': k, 'value': v, 'is_literal': True, 'is_runtime': True, 'is_buildtime': False}
            for k, v in sorted(changed_env.items())]})
    if changed_image:
        call('PATCH', app_path, {'docker_registry_image_name': config['image'], 'docker_registry_image_tag': tag})
    rolling_guard(call('GET', app_path))
    call('POST', '/api/v1/deploy?uuid=' + config['app_uuid'])
    return 'deployed'


class API:
    def __init__(self, base, token):
        self.base = base.rstrip('/')
        self.token = token

    def __call__(self, method, path, payload=None):
        req = urllib.request.Request(self.base + path, method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + self.token,
                     'Accept': 'application/json', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=40) as response:
            data = response.read()
            return json.loads(data) if data else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    api = API(config['base'], Path(config['token_file']).read_text().strip())
    failed = False
    for app in config['applications']:
        try:
            print(app['name'] + ': ' + reconcile(app, api, apply=args.apply), flush=True)
        except Exception as error:
            failed = True
            print(app['name'] + ': failed (' + type(error).__name__ + '); current public container retained.', file=sys.stderr, flush=True)
    return int(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Rolling follower failed (' + type(error).__name__ + ').', file=sys.stderr)
        sys.exit(1)
