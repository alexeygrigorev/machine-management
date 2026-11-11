"""Exercise installer upgrades with a host manifest override and fake services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'install-rolling-follower.sh'


class InstallerTests(unittest.TestCase):
    def test_install_and_upgrade_preserve_local_manifest_until_explicit_update(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binaries = home / 'bin'
            binaries.mkdir()
            commands = {
                'git': '#!/bin/sh\ncase "$*" in *rev-parse*) echo fixture-revision;; esac\n',
                'systemctl': '#!/bin/sh\nexit 0\n',
                'crontab': '#!/bin/sh\nif [ "$1" = -l ]; then echo "# preserved cron"; else cat >/dev/null; fi\n',
            }
            for name, content in commands.items():
                path = binaries / name
                path.write_text(content)
                path.chmod(0o755)
            environment = {**os.environ, 'HOME': str(home),
                           'PATH': str(binaries) + os.pathsep + os.environ['PATH']}

            def install(*args):
                return subprocess.run(['bash', str(INSTALLER), *args], env=environment,
                                      capture_output=True, text=True, check=True)

            manifest = home / '.config/coolify-rolling-web.json'
            install()
            repository = INSTALLER.with_name('coolify-rolling-web.json').read_bytes()
            self.assertEqual(manifest.read_bytes(), repository)
            config = json.loads(repository)
            config['applications'][0]['resource_limits']['limits_memory'] = '3g'
            override = json.dumps(config).encode()
            manifest.write_bytes(override)
            result = install()
            self.assertIn('Preserved existing follower manifest', result.stdout)
            self.assertEqual(manifest.read_bytes(), override)
            self.assertTrue(any(p.read_bytes() == override for p in manifest.parent.glob('*.bak-*')))
            self.assertEqual((home / '.local/lib/coolify-rolling-web/current').readlink(),
                             Path('fixture-revision'))
            install('--update-config')
            self.assertEqual(manifest.read_bytes(), repository)
