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

ASSET_TARGETS = {'rolling-healthcheck.py': '/opt/coolify-healthcheck.py',
                 'rolling-readiness.py': '/opt/rolling-readiness.py',
                 'rolling-launch.py': '/opt/rolling-launch.py'}


def asset_path(uuid, filename, digest):
    if not re.fullmatch('[a-z0-9]+', uuid) or filename not in ASSET_TARGETS or not re.fullmatch('[a-f0-9]{64}', digest):
        raise ValueError('Invalid versioned helper reference')
    return f'/data/coolify/rolling-assets/{uuid}/{digest}/{filename}'


def verify_asset_bindings(config, call, app_path):
    storages = call('GET', app_path + '/storages')['file_storages']
    for filename, target in ASSET_TARGETS.items():
        storage = next((s for s in storages if s['mount_path'] == target), {})
        expected = asset_path(config['app_uuid'], filename, config['asset_hashes'][filename])
        if storage.get('fs_path') != expected or not storage.get('is_host_file'):
            raise ValueError('Helper binding is stale; keep current public release')


def labels_for_web(source_labels, source_uuid, app_uuid, path, health_port=None, application_uuid=None, priority=100):
    """Independent router identities; preserve HTTPS and origin allow/deny priority."""
    labels = {}
    for line in source_labels:
        key, _, value = line.partition('=')
        if key.startswith('traefik.'):
            labels[key.replace(source_uuid, app_uuid)] = value.replace(source_uuid, app_uuid)
    labels['traefik.docker.network'] = 'coolify'
    if application_uuid:
        labels['dtc.rolling-web.application'] = application_uuid
    labels['traefik.http.middlewares.rolling-retry.retry.attempts'] = '3'
    labels['traefik.http.middlewares.rolling-retry.retry.initialinterval'] = '100ms'
    for key in list(labels):
        if key.startswith('traefik.http.routers.') and key.endswith('.rule'):
            prefix = key.removesuffix('.rule')
            labels[prefix + '.priority'] = str(priority)
            middlewares = labels.get(prefix + '.middlewares', '')
            if 'redirect-to-https' not in middlewares:
                labels[prefix + '.middlewares'] = ','.join(filter(None, [middlewares, 'rolling-retry']))
        if key.endswith('.loadbalancer.server.port'):
            prefix = key.removesuffix('.server.port')
            labels[prefix + '.healthcheck.path'] = path
            if health_port:
                labels[prefix + '.healthcheck.port'] = str(health_port)
            labels[prefix + '.healthcheck.hostname'] = 'localhost'
            labels[prefix + '.healthcheck.interval'] = '2s'
            labels[prefix + '.healthcheck.timeout'] = '1s'
            labels[prefix + '.serverstransport'] = 'rolling-web@file'
    return '\n'.join(k + '=' + str(v) for k, v in sorted(labels.items()))


def rolling_guard(app, allowed_build_packs=('dockerimage',)):
    settings = app.get('settings') or {}
    labels = base64.b64decode(app.get('custom_labels') or '').decode()
    if (app.get('build_pack') not in allowed_build_packs or app.get('ports_mappings')
            or settings.get('is_consistent_container_name_enabled')
            or settings.get('custom_internal_name')
            or re.search(r'--(?:ip6?|name|publish)(?:[=\s]|$)|(?:^|\s)-p(?:\s|$)', app.get('custom_docker_run_options') or '')
            or not app.get('health_check_enabled')
            or '.loadbalancer.healthcheck.path=/ready' not in labels
            or '.loadbalancer.healthcheck.port=8099' not in labels
            or 'dtc.rolling-web.application=' not in labels
            or '8099/ready' not in (app.get('health_check_command') or '')
            or '/opt/rolling-launch.py' not in (app.get('custom_docker_run_options') or '')):
        raise ValueError('Native application is not eligible for health-gated rolling updates')


def source_state(config):
    uuid = config['source_uuid']
    if not re.fullmatch('[a-z0-9]+', uuid):
        raise ValueError('Invalid source identifier')
    ssh = ['ssh', '-F', config.get('ssh_config', '/home/alexey/.ssh/config'),
        '-i', config.get('ssh_identity', '/home/alexey/.ssh/id_contabo'),
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', config['ssh_host']]
    if config.get('source_container_prefix'):
        prefix = config['source_container_prefix']
        if not re.fullmatch(r'[a-zA-Z0-9_.-]+', prefix):
            raise ValueError('Invalid source container prefix')
        ids = subprocess.check_output(ssh + ['sudo docker ps -q --filter name=' + shlex.quote(prefix)], text=True, timeout=30).split()
        if not ids or not all(re.fullmatch('[a-f0-9]{12,64}', item) for item in ids):
            raise ValueError('No running source web container')
        cmd = 'sudo docker inspect ' + ' '.join(ids)
    else:
        cmd = 'sudo docker inspect ' + shlex.quote('web-' + uuid)
    result = subprocess.run(ssh + [cmd],
        check=True, capture_output=True, text=True, timeout=30)
    healthy = [c for c in json.loads(result.stdout) if c['State'].get('Health', {}).get('Status') == 'healthy']
    if not healthy:
        raise ValueError('Source web is not healthy; keeping public application')
    container = max(healthy, key=lambda c: c.get('Created', ''))
    env = dict(item.split('=', 1) for item in container['Config']['Env'])
    # Deployment metadata belongs to the new application, not the source stack.
    env = {k: v for k, v in env.items() if not k.startswith(('COOLIFY_', 'SERVICE_'))}
    env['ROLLING_ORIGINAL_ENTRYPOINT'] = shlex.join(container['Config'].get('Entrypoint') or [])
    env['ROLLING_ORIGINAL_COMMAND'] = json.dumps(container['Config'].get('Cmd') or [])
    env.update(config.get('environment', {}))
    return container['Config']['Image'], env


def reconcile(config, call, state=source_state, apply=False):
    image, env = state(config)
    git_mode = config.get('rollout_mode') == 'git-commit'
    tag_pattern = r'[a-f0-9]{40}' if git_mode else r'\d{8}-\d{6}-[a-f0-9]{7,40}'
    if not re.fullmatch(re.escape(config['image']) + ':' + tag_pattern, image):
        raise ValueError('Source image is outside the promoted immutable repository')
    app_path = '/api/v1/applications/' + config['app_uuid']
    app = call('GET', app_path)
    allowed_build_packs = ('dockerfile',) if git_mode else ('dockerimage',)
    rolling_guard(app, allowed_build_packs)
    if config.get('asset_hashes'):
        verify_asset_bindings(config, call, app_path)
    queues = call('GET', '/api/v1/deployments/applications/' + config['app_uuid'])
    deployments = queues.get('deployments', []) if isinstance(queues, dict) else queues
    if any(d.get('status') in ('queued', 'in_progress') for d in deployments):
        return 'busy'
    # Coolify serializes an empty literal as null on readback. Normalize that
    # roundtrip so images without an entrypoint do not redeploy every minute.
    env_records = call('GET', app_path + '/envs')
    current_env = {e['key']: e.get('value') or '' for e in env_records
                   if not e.get('is_preview')}
    # A development release can supply code without supplying production's
    # database, credentials or send policy. These values belong to the native
    # destination's normal secrets/configuration path, never the source stack.
    env = dict(env)
    runtime_env = {e['key']: e.get('value') or '' for e in env_records
                   if not e.get('is_preview') and e.get('is_runtime', True)}
    for key in config.get('destination_environment', []):
        if not runtime_env.get(key):
            raise ValueError('Destination environment is incomplete; keep current public release')
        env.pop(key, None)
    for key in config.get('destination_environment_optional', []):
        env.pop(key, None)
    build_flags = {e['key']: bool(e.get('is_buildtime')) for e in env_records if not e.get('is_preview')}
    changed_env = {k: v for k, v in env.items() if current_env.get(k) != v}
    tag = image.rsplit(':', 1)[1]
    changed_image = app.get('git_commit_sha') != tag if git_mode else (
        app.get('docker_registry_image_tag') != tag or app.get('docker_registry_image_name') != config['image'])
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
            {'key': k, 'value': v, 'is_literal': True, 'is_runtime': True, 'is_buildtime': build_flags.get(k, False)}
            for k, v in sorted(changed_env.items())]})
    if changed_image:
        payload = {'git_commit_sha': tag} if git_mode else {'docker_registry_image_name': config['image'], 'docker_registry_image_tag': tag}
        call('PATCH', app_path, payload)
    rolling_guard(call('GET', app_path), allowed_build_packs)
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


def verify_control_plane(config):
    expected = config['control_plane']
    output = subprocess.check_output(['ssh', '-F', '/home/alexey/.ssh/config',
        '-i', '/home/alexey/.ssh/id_contabo', '-o', 'BatchMode=yes', expected['ssh_host'],
        'sudo docker exec coolify sha256sum app/Jobs/ApplicationDeploymentJob.php'],
        text=True, stderr=subprocess.DEVNULL, timeout=30)
    if output.split()[0] != expected['job_sha256']:
        raise ValueError('Control-plane drain hook is missing or changed; keep current public release')


def verify_host_assets(config):
    hosts = {}
    for app in config['applications']:
        for filename, digest in config['assets'].items():
            path = asset_path(app['app_uuid'], filename, digest)
            hosts.setdefault(app['ssh_host'], {})[path] = digest
    for host, expected in hosts.items():
        output = subprocess.check_output(['ssh', '-F', '/home/alexey/.ssh/config',
            '-i', '/home/alexey/.ssh/id_contabo', '-o', 'BatchMode=yes', host,
            'sudo sha256sum -- ' + shlex.join(sorted(expected))], text=True,
            stderr=subprocess.DEVNULL, timeout=30)
        actual = {line.split(maxsplit=1)[1].strip(): line.split()[0] for line in output.splitlines()}
        if actual != expected:
            raise ValueError('Host helper content does not match manifest; keep current public release')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    verify_control_plane(config)
    verify_host_assets(config)
    api = API(config['base'], Path(config['token_file']).read_text().strip())
    failed = False
    for app in config['applications']:
        try:
            app = {**app, 'asset_hashes': config['assets']}
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
