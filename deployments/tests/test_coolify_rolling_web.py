import copy
import base64
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('rolling', Path(__file__).parents[1] / 'coolify-rolling-web.py')
rolling = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rolling)


class RollingTests(unittest.TestCase):
    def setUp(self):
        self.config = {'source_uuid': 'source', 'app_uuid': 'native', 'image': 'ghcr.io/org/web'}
        self.app = {'build_pack': 'dockerimage', 'health_check_enabled': True,
                    'custom_labels': base64.b64encode(b'traefik.http.services.web.loadbalancer.healthcheck.path=/ping').decode(),
                    'settings': {}, 'docker_registry_image_name': 'ghcr.io/org/web',
                    'docker_registry_image_tag': '20261023-120000-abcdef0'}
        self.env = [{'key': 'SECRET', 'value': 'private', 'is_preview': False}]
        self.deployments = [{'status': 'finished'}]
        self.writes = []

    def call(self, method, path, data=None):
        if method != 'GET':
            self.writes.append((method, path, data))
            if path == '/api/v1/applications/native':
                self.app.update(data)
            return {}
        if '/deployments/' in path:
            return {'deployments': self.deployments}
        return self.env if path.endswith('/envs') else copy.deepcopy(self.app)

    def state(self, config):
        return 'ghcr.io/org/web:20261023-120000-abcdef0', {'SECRET': 'private'}

    def test_same_release_is_no_write_and_no_deploy(self):
        self.assertEqual(rolling.reconcile(self.config, self.call, self.state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_new_release_updates_then_deploys_native_only(self):
        def new(config):
            return 'ghcr.io/org/web:20261023-130000-123abcd', {'SECRET': 'private'}
        self.assertEqual(rolling.reconcile(self.config, self.call, new, True), 'deployed')
        self.assertEqual([w[:2] for w in self.writes], [
            ('PATCH', '/api/v1/applications/native'), ('POST', '/api/v1/deploy?uuid=native')])

    def test_failed_release_is_retried_instead_of_false_convergence(self):
        self.deployments = [{'status': 'failed'}]
        self.assertEqual(rolling.reconcile(self.config, self.call, self.state, True), 'deployed')
        self.assertEqual(self.writes[-1][1], '/api/v1/deploy?uuid=native')

    def test_busy_application_is_not_redeployed(self):
        self.deployments = [{'status': 'in_progress'}]
        self.assertEqual(rolling.reconcile(self.config, self.call, self.state, True), 'busy')
        self.assertEqual(self.writes, [])

    def test_unsafe_settings_refuse_writes(self):
        for key, value in [('ports_mappings', '8000:8000'), ('health_check_enabled', False),
                           ('custom_docker_run_options', '--ip=10.0.0.2')]:
            with self.subTest(key=key):
                app = {**self.app, key: value}
                with self.assertRaises(ValueError):
                    rolling.rolling_guard(app)

    def test_mutable_or_foreign_source_refused(self):
        for image in ['ghcr.io/org/web:latest', 'ghcr.io/other/web:20261023-120000-abcdef0']:
            with self.assertRaises(ValueError):
                rolling.reconcile(self.config, self.call, lambda c: (image, {}), True)
        self.assertEqual(self.writes, [])

    def test_missing_traefik_healthgate_refuses_deploy(self):
        self.app['custom_labels'] = ''
        with self.assertRaises(ValueError):
            rolling.reconcile(self.config, self.call, self.state, True)
        self.assertEqual(self.writes, [])

    def test_unhealthy_source_cannot_modify_public_application(self):
        def unhealthy(config):
            raise ValueError('source unhealthy')
        with self.assertRaises(ValueError):
            rolling.reconcile(self.config, self.call, unhealthy, True)
        self.assertEqual(self.writes, [])

    def test_env_rotation_is_literal_and_does_not_delete_secrets(self):
        def changed(config):
            return self.state(config)[0], {'SECRET': 'new$literal'}
        self.assertEqual(rolling.reconcile(self.config, self.call, changed, True), 'deployed')
        self.assertEqual(self.writes[0][1], '/api/v1/applications/native/envs/bulk')
        self.assertTrue(self.writes[0][2]['data'][0]['is_literal'])
        self.assertFalse(any(w[0] == 'DELETE' for w in self.writes))

    def test_proxy_labels_keep_origin_guard_priority_and_healthgate(self):
        labels = rolling.labels_for_web([
            'traefik.http.routers.http-source.rule=Host(`example.test`)',
            'traefik.http.routers.http-source.middlewares=gzip',
            'traefik.http.services.http-source.loadbalancer.server.port=8000',
            'coolify.managed=true'], 'source', 'native', '/ping')
        self.assertIn('http-native.priority=100', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.path=/ping', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.hostname=localhost', labels)
        self.assertIn('http-native.loadbalancer.serverstransport=rolling-web@file', labels)
        self.assertIn('http-native.middlewares=gzip,rolling-retry', labels)
        self.assertNotIn('coolify.managed', labels)


if __name__ == '__main__':
    unittest.main()
