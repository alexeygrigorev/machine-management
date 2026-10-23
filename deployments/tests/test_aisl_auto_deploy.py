import base64
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

import yaml

spec = importlib.util.spec_from_file_location('poller', Path(__file__).parents[1] / 'aisl-auto-deploy.py')
poller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(poller)
TAG = '20261022-163449-f2d6550'
OLD = '20261021-123456-abcdef0'


def fixture(tag=TAG):
    return {'docker_compose_raw': yaml.safe_dump({'services': {
        'web': {'image': poller.IMAGE + ':' + tag, 'pull_policy': 'missing', 'environment': {'SECRET_KEY': '${SECRET_KEY}'}},
        'worker': {'image': poller.IMAGE + ':' + tag, 'pull_policy': 'missing', 'environment': {'BOOT_MODE': 'worker'}},
        'unrelated': {'image': 'redis:7', 'pull_policy': 'always'}}}),
        'applications': [{'name': 'worker', 'image': 'ai-shipping-labs/website:' + tag},
                         {'name': 'web', 'image': poller.IMAGE + ':' + tag}]}


class PollerTests(unittest.TestCase):
    def test_same_tag_with_optional_ghcr_prefix_never_writes_or_deploys(self):
        calls = []
        service = fixture()
        def call(method, path, payload=None):
            calls.append(method)
            self.assertEqual(method, 'GET')
            return service
        self.assertEqual(poller.reconcile(call, TAG, apply=True), 'in-sync')
        self.assertEqual(calls, ['GET'])

    def test_new_tag_updates_web_and_worker_once_then_becomes_noop(self):
        state = fixture(OLD)
        original = yaml.safe_load(state['docker_compose_raw'])
        calls = []
        def call(method, path, payload=None):
            calls.append(method)
            if method == 'PATCH':
                state['docker_compose_raw'] = base64.b64decode(payload['docker_compose_raw']).decode()
            if method == 'POST':
                for app in state['applications']:
                    app['image'] = poller.IMAGE + ':' + TAG
            return copy.deepcopy(state)
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(poller.reconcile(call, TAG, True, Path(directory)), 'deployed')
            self.assertEqual(poller.reconcile(call, TAG, True, Path(directory)), 'in-sync')
        self.assertEqual(calls.count('PATCH'), 1)
        self.assertEqual(calls.count('POST'), 1)
        final = yaml.safe_load(state['docker_compose_raw'])
        for name in ('web', 'worker'):
            self.assertEqual(final['services'][name]['image'], poller.IMAGE + ':' + TAG)
            self.assertEqual(final['services'][name]['pull_policy'], 'missing')
            self.assertEqual(final['services'][name]['environment'], original['services'][name]['environment'])
        self.assertEqual(final['services']['unrelated'], original['services']['unrelated'])

    def test_policy_drift_does_not_request_deployment(self):
        service = fixture()
        service['docker_compose_raw'] = service['docker_compose_raw'].replace('pull_policy: missing', 'pull_policy: always')
        updated, deploy = poller.plan(service, TAG)
        self.assertFalse(deploy)
        for name in ('web', 'worker'):
            self.assertEqual(yaml.safe_load(updated)['services'][name]['pull_policy'], 'missing')

    def test_conflicting_worker_or_mutable_tag_fails_closed(self):
        service = fixture()
        for tag in ('latest', 'sha-abc'):
            with self.assertRaises(ValueError):
                poller.plan(service, tag)
        compose = yaml.safe_load(service['docker_compose_raw'])
        compose['services']['worker']['image'] = 'other/repo:latest'
        service['docker_compose_raw'] = yaml.safe_dump(compose)
        with self.assertRaises(ValueError):
            poller.plan(service, TAG)

    def test_concurrent_edit_prevents_mutation(self):
        service = fixture(OLD)
        calls = []
        def call(method, path, payload=None):
            calls.append(method)
            self.assertEqual(method, 'GET')
            result = copy.deepcopy(service)
            if len(calls) > 1:
                result['docker_compose_raw'] += '\n# concurrent edit\n'
            return result
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            poller.reconcile(call, TAG, True, Path(directory))
        self.assertEqual(calls, ['GET', 'GET'])


if __name__ == '__main__':
    unittest.main()
