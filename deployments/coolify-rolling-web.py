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


def collapse_duplicate_services(labels):
    """Point equivalent routers at one backend service and remove duplicates."""
    properties = {}
    for key, value in labels.items():
        match = re.fullmatch(r'traefik\.http\.services\.([^.]+)\.(.+)', key)
        if match:
            properties.setdefault(match.group(1), {})[match.group(2)] = value
    if len(properties) < 2:
        return
    fingerprints = list(properties.values())
    if any(fingerprint != fingerprints[0] for fingerprint in fingerprints[1:]):
        return

    names = set(properties)
    canonical = sorted(names)[0]
    for key in list(labels):
        match = re.fullmatch(r'traefik\.http\.routers\.([^.]+)\.service', key)
        if not match:
            continue
        router = match.group(1)
        reference = labels[key]
        name, separator, provider = reference.partition('@')
        if name in names:
            labels[key] = canonical + (separator + provider if separator else '')
        elif not separator and router in names:
            labels[key] = canonical

    for key in list(labels):
        match = re.fullmatch(r'traefik\.http\.services\.([^.]+)\..+', key)
        if match and match.group(1) in names - {canonical}:
            del labels[key]


def labels_for_web(source_labels, source_uuid, app_uuid, path, health_port=None,
                   application_uuid=None, priority=None, extra_middlewares=(),
                   preserve_non_traefik=False, collapse_services=False):
    """Set resilient proxy labels and collapse identical per-domain backends."""
    labels = {}
    for line in source_labels:
        key, _, value = line.partition('=')
        if key.startswith('traefik.'):
            labels[key.replace(source_uuid, app_uuid)] = value.replace(source_uuid, app_uuid)
        elif preserve_non_traefik and key:
            labels[key] = value
    labels['traefik.docker.network'] = 'coolify'
    if application_uuid:
        labels['dtc.rolling-web.application'] = application_uuid
    labels['traefik.http.middlewares.rolling-retry.retry.attempts'] = '3'
    labels['traefik.http.middlewares.rolling-retry.retry.initialinterval'] = '100ms'

    if collapse_services:
        collapse_duplicate_services(labels)
    for key in list(labels):
        if key.startswith('traefik.http.routers.') and key.endswith('.rule'):
            prefix = key.removesuffix('.rule')
            if priority is not None or prefix + '.priority' not in labels:
                labels[prefix + '.priority'] = str(priority if priority is not None else 100)
            middlewares = []
            seen = set()
            for item in labels.get(prefix + '.middlewares', '').split(','):
                item = item.strip()
                if not item:
                    continue
                identity = 'rolling-retry' if item.split('@', 1)[0] == 'rolling-retry' else item
                if identity not in seen:
                    seen.add(identity)
                    middlewares.append(item)
            serving_router = not any('redirect-to-https' in item for item in middlewares)
            additions = ['rolling-retry', *extra_middlewares] if serving_router else []
            for middleware in additions:
                identity = 'rolling-retry' if middleware.split('@', 1)[0] == 'rolling-retry' else middleware
                if identity not in seen:
                    seen.add(identity)
                    middlewares.append(middleware)
            if middlewares:
                labels[prefix + '.middlewares'] = ','.join(middlewares)
        if key.endswith('.loadbalancer.server.port'):
            prefix = key.removesuffix('.server.port')
            labels[prefix + '.healthcheck.path'] = path
            if health_port:
                labels[prefix + '.healthcheck.port'] = str(health_port)
            labels[prefix + '.healthcheck.hostname'] = 'localhost'
            labels[prefix + '.healthcheck.interval'] = '5s'
            labels[prefix + '.healthcheck.timeout'] = '3s'
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
            or '.loadbalancer.healthcheck.interval=5s' not in labels
            or '.loadbalancer.healthcheck.timeout=3s' not in labels
            or 'dtc.rolling-web.application=' not in labels
            or '/opt/coolify-healthcheck.py' not in (app.get('health_check_command') or '')
            or '8099/ready' in (app.get('health_check_command') or '')
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


def source_image_tag_pattern(config):
    """Return the configured immutable source tag format."""
    if config.get('rollout_mode') == 'git-commit':
        return r'[a-f0-9]{40}'
    formats = {
        'dated': r'\d{8}-\d{6}-[a-f0-9]{7,40}',
        # AISHL deploy-dev.yml tags every image with the immutable workflow
        # run, attempt and full Git commit SHA.
        'github-run': r'deploy-\d+-\d+-[a-f0-9]{40}',
    }
    tag_format = config.get('source_tag_format', 'dated')
    if tag_format not in formats:
        raise ValueError('Unknown immutable source tag format')
    return formats[tag_format]


def verify_routing_overlap(config, desired_labels):
    """Traefik rejects duplicate named definitions when properties differ."""
    uuid = config['app_uuid']
    if not re.fullmatch('[a-z0-9]+', uuid):
        raise ValueError('Invalid application identifier')
    output = subprocess.check_output(['ssh', '-o', 'BatchMode=yes', config['ssh_host'],
        'sudo docker inspect --format ' + shlex.quote('{{json .Config.Labels}}') +
        ' $(sudo docker ps -q --filter label=dtc.rolling-web.application=' + uuid + ')'],
        text=True, stderr=subprocess.DEVNULL, timeout=30)

    def definitions(labels):
        result = {}
        for key, value in labels.items():
            if re.match(r'traefik\.http\.(services|routers|middlewares)\.', key):
                entity, property = '.'.join(key.split('.')[:4]), '.'.join(key.split('.')[4:])
                result.setdefault(entity, {})[property] = str(value)
        return result

    desired = definitions(dict(line.split('=', 1) for line in desired_labels.splitlines() if '=' in line))
    live_rows = [json.loads(line) for line in output.splitlines() if line.strip()]
    if not live_rows:
        raise ValueError('Cannot verify live routing overlap; retain current release')
    for labels in live_rows:
        live = definitions(labels)
        if any(live[name] != desired[name] for name in live.keys() & desired.keys()):
            raise ValueError('Routing configuration conflicts with live replica; separate namespace migration required')


def reconcile(config, call, state=source_state, apply=False):
    image, env = state(config)
    git_mode = config.get('rollout_mode') == 'git-commit'
    tag_pattern = source_image_tag_pattern(config)
    if not re.fullmatch(re.escape(config['image']) + ':' + tag_pattern, image):
        raise ValueError('Source image is outside the promoted immutable repository')
    app_path = '/api/v1/applications/' + config['app_uuid']
    app = call('GET', app_path)
    allowed_build_packs = ('dockerfile',) if git_mode else ('dockerimage',)

    desired_labels = app.get('custom_labels') or ''
    desired_health_check = app.get('health_check_command')
    if config.get('manage_labels'):
        current_label_lines = base64.b64decode(desired_labels).decode().splitlines()
        label_text = labels_for_web(
            current_label_lines, config['app_uuid'], config['app_uuid'], '/ready',
            health_port=8099, application_uuid=config['app_uuid'],
            extra_middlewares=config.get('proxy_middlewares', ()),
            preserve_non_traefik=True,
            collapse_services=config.get('collapse_services', False))
        desired_labels = base64.b64encode(label_text.encode()).decode()
        desired_health_check = config.get('health_check_command', desired_health_check)
    guarded_app = {**app, 'custom_labels': desired_labels,
                   'health_check_command': desired_health_check}
    rolling_guard(guarded_app, allowed_build_packs)
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
    changed_labels = desired_labels != (app.get('custom_labels') or '')
    changed_health_check = desired_health_check != app.get('health_check_command')
    changed_limits = {key: value for key, value in config.get('resource_limits', {}).items()
                      if app.get(key) != value}
    tag = image.rsplit(':', 1)[1]
    changed_image = app.get('git_commit_sha') != tag if git_mode else (
        app.get('docker_registry_image_tag') != tag or app.get('docker_registry_image_name') != config['image'])
    # Reconcile failed or interrupted deployments too, even when desired metadata
    # already has the target tag. Never let a failed rollout look converged.
    last = deployments[0] if deployments else {}
    needs_retry = last.get('status') in ('failed', 'cancelled', 'cancelled-by-user')
    if not changed_env and not changed_image and not changed_labels and not changed_health_check and not changed_limits and not needs_retry:
        return 'in-sync'
    if config.get('guard_routing_overlap'):
        verify_routing_overlap(config, base64.b64decode(desired_labels).decode())
    if not apply:
        return 'planned'
    if changed_env:
        call('PATCH', app_path + '/envs/bulk', {'data': [
            {'key': k, 'value': v, 'is_literal': True, 'is_runtime': True, 'is_buildtime': build_flags.get(k, False)}
            for k, v in sorted(changed_env.items())]})
    app_patch = dict(changed_limits)
    if changed_image:
        app_patch.update({'git_commit_sha': tag} if git_mode else {
            'docker_registry_image_name': config['image'], 'docker_registry_image_tag': tag})
    if changed_labels:
        app_patch['custom_labels'] = desired_labels
    if changed_health_check:
        app_patch['health_check_command'] = desired_health_check
    if app_patch:
        call('PATCH', app_path, app_patch)
    rolling_guard(call('GET', app_path), allowed_build_packs)
    call('POST', '/api/v1/deploy?uuid=' + config['app_uuid'])
    return 'deployed'


def active_rollout(config, call):
    """Return the first active follower application before starting another."""
    for app in config['applications']:
        response = call('GET', '/api/v1/deployments/applications/' + app['app_uuid'])
        deployments = response.get('deployments', []) if isinstance(response, dict) else response
        if any(d.get('status') in ('queued', 'in_progress') for d in deployments):
            return app['name']
    return None


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
    active = active_rollout(config, api)
    if active:
        print(active + ': busy (another configured rollout is active)', flush=True)
        return 0
    failed = False
    for app in config['applications']:
        try:
            app = {**app, 'asset_hashes': config['assets']}
            result = reconcile(app, api, apply=args.apply)
            print(app['name'] + ': ' + result, flush=True)
            # Promote or mutate one public app per cron run. On the next run,
            # a queued/in-progress deployment stops the remaining apps too.
            if result in ('deployed', 'busy'):
                break
        except Exception as error:
            failed = True
            print(app['name'] + ': failed (' + type(error).__name__ + '); current public container retained.', file=sys.stderr, flush=True)
            break
    return int(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Rolling follower failed (' + type(error).__name__ + ').', file=sys.stderr)
        sys.exit(1)
