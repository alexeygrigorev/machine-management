"""Deployment regression checks: worker cannot inherit web ingress or migrations."""
import importlib.util
from pathlib import Path
import unittest

import yaml

spec = importlib.util.spec_from_file_location('deploy', Path(__file__).parents[1] / 'aisl-qcluster.py')
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class WorkerComposeTest(unittest.TestCase):
    def test_preserves_web_but_does_not_copy_ingress_or_migrations(self):
        compose = {'services': {'web': {
            'image': 'example/image:immutable-tag',
            'environment': {'RUN_MIGRATIONS': 'true', 'DEBUG': '0'},
            'labels': ['traefik.enable=true'], 'ports': ['8000:8000'],
            'expose': ['8000'], 'networks': ['database'],
            'env_file': ['.env'],
        }}, 'networks': {'database': {'external': True}}}
        updated = yaml.safe_load(deploy.add_worker(yaml.safe_dump(compose)))
        self.assertEqual(updated['services']['web'], compose['services']['web'])
        self.assertEqual(updated['networks'], compose['networks'])
        worker = updated['services']['worker']
        self.assertEqual(worker['image'], compose['services']['web']['image'])
        self.assertEqual(worker['environment']['BOOT_MODE'], 'worker')
        self.assertEqual(worker['environment']['RUN_MIGRATIONS'], 'false')
        self.assertEqual(worker['env_file'], ['.env'])
        self.assertEqual(worker['networks'], ['database'])
        self.assertTrue({'ports', 'expose', 'labels'}.isdisjoint(worker))
        self.assertEqual(worker['healthcheck']['test'][1], '/app/.venv/bin/python')

    def test_list_environment_and_idempotent_plan(self):
        raw = yaml.safe_dump({'services': {'web': {
            'image': 'example/image:tag',
            'environment': ['RUN_MIGRATIONS=true', 'SECRET_KEY', 'OTHER=a=b'],
        }}})
        updated = deploy.add_worker(raw)
        env = yaml.safe_load(updated)['services']['worker']['environment']
        self.assertIsNone(env['SECRET_KEY'])
        self.assertEqual(env['OTHER'], 'a=b')
        self.assertEqual(deploy.add_worker(updated), updated)

    def test_refuses_to_overwrite_an_unrelated_worker(self):
        raw = yaml.safe_dump({'services': {'web': {'image': 'example:one'},
                                          'worker': {'image': 'example:two'}}})
        with self.assertRaisesRegex(ValueError, 'existing worker differs'):
            deploy.add_worker(raw)


if __name__ == '__main__':
    unittest.main()
