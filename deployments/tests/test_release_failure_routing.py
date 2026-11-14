"""Each release poller must alert under its own name (2026-11-14 incident).

The CMP release poller reused coolify-rolling-web-failure.service, so every
GitHub API 403 it hit sent "[infra] production release follower failed" every
five minutes while coolify-rolling-web.service itself was green.
"""
import configparser
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

DEPLOYMENTS = Path(__file__).resolve().parents[1]


def unit(name):
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read_string((DEPLOYMENTS / name).read_text())
    return parser


class FailureRoutingTests(unittest.TestCase):
    def test_each_poller_has_its_own_failure_unit(self):
        self.assertEqual(unit('coolify-rolling-web.service')['Unit']['OnFailure'],
                         'coolify-rolling-web-failure.service')
        self.assertEqual(unit('cmp-release-poller.service')['Unit']['OnFailure'],
                         'cmp-release-poller-failure.service')
        self.assertTrue(unit('coolify-rolling-web-failure.service')['Service']['ExecStart']
                        .endswith('/rolling-follower-failure.sh'))
        self.assertTrue(unit('cmp-release-poller-failure.service')['Service']['ExecStart']
                        .endswith('/rolling-follower-failure.sh cmp-release-poller'))

    def test_installers_ship_the_cmp_failure_unit(self):
        for installer in ('install-rolling-follower.sh', 'install-cmp-release-poller.sh'):
            with self.subTest(installer=installer):
                loops = [line for line in (DEPLOYMENTS / installer).read_text().splitlines()
                         if line.startswith('for unit in ')]
                self.assertTrue(any('cmp-release-poller-failure.service' in line for line in loops))

    def test_follower_unit_tracks_source_replacement_state(self):
        self.assertIn('--state %h/.local/state/coolify-rolling-web-source.json --apply',
                      unit('coolify-rolling-web.service')['Service']['ExecStart'])

    def send(self, *args):
        with tempfile.TemporaryDirectory() as directory:
            binaries = Path(directory)
            capture = binaries / 'mail'
            ssh = binaries / 'ssh'
            ssh.write_text('#!/bin/sh\necho "$*" > "%s.args"\ncat > "%s"\n' % (capture, capture))
            ssh.chmod(0o755)
            environment = {**os.environ, 'PATH': str(binaries) + os.pathsep + os.environ['PATH']}
            result = subprocess.run(['bash', str(DEPLOYMENTS / 'rolling-follower-failure.sh'), *args],
                                    env=environment, capture_output=True, text=True)
            mail = capture.read_text() if capture.exists() else None
            ssh_args = capture.with_suffix('.args').read_text() if capture.exists() else None
            return result, mail, ssh_args

    def test_alerts_name_the_failed_component(self):
        result, mail, ssh_args = self.send()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Subject: [infra] production release follower failed\n', mail)
        self.assertIn('journalctl --user -u coolify-rolling-web.service', mail)
        self.assertIn('contabo-a sudo msmtp -a alerts dev@dtcdev.click', ssh_args)

        result, mail, _ = self.send('cmp-release-poller')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Subject: [infra] CMP release poller failed\n', mail)
        self.assertIn('journalctl --user -u cmp-release-poller.service', mail)
        self.assertNotIn('release follower', mail)

        result, mail, _ = self.send('anything-else')
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(mail)


if __name__ == '__main__':
    unittest.main()
