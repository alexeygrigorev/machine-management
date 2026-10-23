#!/usr/bin/env python3
"""Install versioned web readiness helpers and bind their exact host paths.

Coolify preserves existing generated content files on disk. Changing only the
database content is insufficient; use new immutable paths for every revision.
Default is read-only. --apply updates only code-file bindings, not containers.
"""
import argparse
import base64
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rolling', HERE / 'coolify-rolling-web.py')
rolling = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rolling)
FILES = {'rolling-healthcheck.py': '/opt/coolify-healthcheck.py',
         'rolling-readiness.py': '/opt/rolling-readiness.py',
         'rolling-launch.py': '/opt/rolling-launch.py'}


def ssh(host, command, data=None):
    return subprocess.run(['ssh', '-F', '/home/alexey/.ssh/config', '-i', '/home/alexey/.ssh/id_contabo',
        '-o', 'BatchMode=yes', host, command], input=data, text=True,
        capture_output=True, check=True, timeout=40).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=HERE / 'coolify-rolling-web.json')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    rolling.verify_control_plane(config)
    api = rolling.API(config['base'], Path(config['token_file']).read_text().strip())
    bindings = []
    backup = {}
    for app in config['applications']:
        uuid = app['app_uuid']
        if not re.fullmatch('[a-z0-9]+', uuid):
            raise ValueError('Invalid application identifier')
        storages = api('GET', '/api/v1/applications/' + uuid + '/storages')['file_storages']
        backup[uuid] = storages
        for filename, target in FILES.items():
            content = (HERE / filename).read_text()
            digest = hashlib.sha256(content.encode()).hexdigest()
            expected = config['assets'][filename]
            if digest != expected:
                raise ValueError('Manifest does not match repository helper content')
            source = f'/data/coolify/rolling-assets/{uuid}/{digest}/{filename}'
            storage = next(s for s in storages if s['mount_path'] == target)
            bindings.append({'application': uuid, 'storage': storage['uuid'], 'path': source})
            if args.apply:
                ssh(app['ssh_host'], 'sudo mkdir -p ' + shlex.quote(str(Path(source).parent)))
                ssh(app['ssh_host'], 'sudo tee ' + shlex.quote(source + '.tmp') + ' >/dev/null', content)
                ssh(app['ssh_host'], 'sudo chmod 444 ' + shlex.quote(source + '.tmp') + ' && sudo mv ' +
                    shlex.quote(source + '.tmp') + ' ' + shlex.quote(source))
    if not args.apply:
        print('Plan: install twelve versioned public code files and update native application bindings.')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    directory = Path('/home/alexey/tmp') / ('coolify-web-assets-backup-' + stamp)
    directory.mkdir(mode=0o700)
    file = directory / 'file-storages.json'
    file.write_text(json.dumps(backup))
    file.chmod(0o600)
    encoded = base64.b64encode(json.dumps(bindings).encode()).decode()
    php = ('$rows = json_decode(base64_decode("' + encoded + '"), true); '
        'foreach ($rows as $row) { '
        '$a = App\\Models\\Application::where("uuid", $row["application"])->firstOrFail(); '
        '$f = $a->fileStorages()->where("uuid", $row["storage"])->firstOrFail(); '
        '$f->fs_path = $row["path"]; $f->is_host_file = true; $f->is_directory = false; '
        '$f->content = null; $f->save(); }')
    ssh(config['control_plane']['ssh_host'], 'sudo docker exec coolify php artisan tinker --execute=' + shlex.quote(php))
    for app in config['applications']:
        current = api('GET', '/api/v1/applications/' + app['app_uuid'] + '/storages')['file_storages']
        for filename, target in FILES.items():
            storage = next(s for s in current if s['mount_path'] == target)
            expected = f'/data/coolify/rolling-assets/{app["app_uuid"]}/{config["assets"][filename]}/{filename}'
            if storage['fs_path'] != expected or not storage.get('is_host_file'):
                raise ValueError('Versioned helper binding did not persist')
    print('Versioned helper files and exact host-file bindings persisted; deploy native applications to adopt.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Asset installation failed (' + type(error).__name__ + '); inspect private configuration.', file=sys.stderr)
        sys.exit(1)
