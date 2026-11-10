import copy
import base64
import importlib.util
import json
import io
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('rolling', Path(__file__).parents[1] / 'coolify-rolling-web.py')
rolling = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rolling)


class RollingTests(unittest.TestCase):
    def test_conflicting_live_service_probe_settings_are_rejected(self):
        config = {'app_uuid': 'native', 'ssh_host': 'node'}
        key = 'traefik.http.services.web.loadbalancer.healthcheck.interval'
        with patch.object(rolling.subprocess, 'check_output', return_value=json.dumps({key: '2s'}) + '\n'):
            with self.assertRaisesRegex(ValueError, 'conflicts'):
                rolling.verify_routing_overlap(config, key + '=5s')
        with patch.object(rolling.subprocess, 'check_output', return_value=json.dumps({key: '5s'}) + '\n'):
            rolling.verify_routing_overlap(config, key + '=5s')

    def test_metadata_match_does_not_hide_conflicting_live_routing(self):
        config = {**self.config, 'guard_routing_overlap': True}
        def new(config):
            return 'ghcr.io/org/web:20261110-120000-abcdef0', {'SECRET': 'private'}
        with patch.object(rolling, 'verify_routing_overlap', side_effect=ValueError('live conflict')):
            with self.assertRaisesRegex(ValueError, 'live conflict'):
                rolling.reconcile(config, self.call, new, True)
        self.assertEqual(self.writes, [])

    def setUp(self):
        self.config = {'source_uuid': 'source', 'app_uuid': 'native', 'image': 'ghcr.io/org/web'}
        self.app = {'build_pack': 'dockerimage', 'health_check_enabled': True,
                    'custom_labels': base64.b64encode(b'traefik.http.services.web.loadbalancer.healthcheck.path=/ready\ntraefik.http.services.web.loadbalancer.healthcheck.port=8099\ntraefik.http.services.web.loadbalancer.healthcheck.interval=5s\ntraefik.http.services.web.loadbalancer.healthcheck.timeout=3s\ndtc.rolling-web.application=native').decode(),
                    'health_check_command': 'python /opt/coolify-healthcheck.py',
                    'custom_docker_run_options': '--entrypoint "python /opt/rolling-launch.py"',
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

    def test_resource_budget_change_rolls_same_image_once(self):
        config = {**self.config, 'resource_limits': {'limits_cpus': '4', 'limits_memory': '1g', 'limits_cpu_shares': 4096}}
        self.assertEqual(rolling.reconcile(config, self.call, self.state, True), 'deployed')
        patch = next(data for method, path, data in self.writes if method == 'PATCH' and path.endswith('/native'))
        self.assertEqual(patch, config['resource_limits'])
        self.writes.clear()
        self.assertEqual(rolling.reconcile(config, self.call, self.state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_empty_environment_roundtrip_does_not_redeploy(self):
        self.env.append({'key': 'ROLLING_ORIGINAL_ENTRYPOINT', 'value': None})
        def state(config):
            image, values = self.state(config)
            return image, {**values, 'ROLLING_ORIGINAL_ENTRYPOINT': ''}
        self.assertEqual(rolling.reconcile(self.config, self.call, state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_control_plane_checksum_must_match_before_reconciliation(self):
        config = {'control_plane': {'ssh_host': 'primary', 'job_sha256': 'expected'}}
        with patch.object(rolling.subprocess, 'check_output', return_value='different  job.php\n'):
            with self.assertRaises(ValueError):
                rolling.verify_control_plane(config)
        with patch.object(rolling.subprocess, 'check_output', return_value='expected  job.php\n'):
            rolling.verify_control_plane(config)

    def test_helper_binding_requires_exact_versioned_host_file(self):
        hashes = {name: 'a' * 64 for name in rolling.ASSET_TARGETS}
        config = {**self.config, 'asset_hashes': hashes}
        storages = [{'mount_path': target, 'fs_path': rolling.asset_path('native', name, hashes[name]),
                     'is_host_file': True} for name, target in rolling.ASSET_TARGETS.items()]
        call = lambda *args: {'file_storages': storages}
        rolling.verify_asset_bindings(config, call, '/api/v1/applications/native')
        for mutation in ({'fs_path': '/data/coolify/stale.py'}, {'is_host_file': False}):
            with self.subTest(mutation=mutation):
                original = storages[0].copy()
                storages[0].update(mutation)
                with self.assertRaises(ValueError):
                    rolling.verify_asset_bindings(config, call, '/api/v1/applications/native')
                storages[0] = original
        storages.pop()
        with self.assertRaises(ValueError):
            rolling.verify_asset_bindings(config, call, '/api/v1/applications/native')

    def test_host_helper_content_must_match_manifest(self):
        config = {'applications': [{'ssh_host': 'node', 'app_uuid': 'native'}],
                  'assets': {'rolling-readiness.py': 'a' * 64}}
        path = rolling.asset_path('native', 'rolling-readiness.py', 'a' * 64)
        with patch.object(rolling.subprocess, 'check_output', return_value='a' * 64 + '  ' + path + '\n'):
            rolling.verify_host_assets(config)
        with patch.object(rolling.subprocess, 'check_output', return_value='b' * 64 + '  ' + path + '\n'):
            with self.assertRaises(ValueError):
                rolling.verify_host_assets(config)

    def test_stale_helper_binding_refuses_deployment(self):
        config = {**self.config, 'asset_hashes': {name: 'a' * 64 for name in rolling.ASSET_TARGETS}}
        def call(method, path, data=None):
            if path.endswith('/storages'):
                return {'file_storages': [{'mount_path': target, 'fs_path': '/old/file', 'is_host_file': True}
                                         for target in rolling.ASSET_TARGETS.values()]}
            return self.call(method, path, data)
        with self.assertRaises(ValueError):
            rolling.reconcile(config, call, self.state, True)
        self.assertEqual(self.writes, [])

    def test_versioned_helper_bindings_allow_same_release_noop(self):
        config = {**self.config, 'asset_hashes': {name: 'a' * 64 for name in rolling.ASSET_TARGETS}}
        def call(method, path, data=None):
            if path.endswith('/storages'):
                return {'file_storages': [{'mount_path': target, 'fs_path': rolling.asset_path('native', name, 'a' * 64), 'is_host_file': True}
                                         for name, target in rolling.ASSET_TARGETS.items()]}
            return self.call(method, path, data)
        self.assertEqual(rolling.reconcile(config, call, self.state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_host_helper_hash_mismatch_refuses_reconciliation(self):
        config = {'applications': [{'app_uuid': 'native', 'ssh_host': 'node'}],
                  'assets': {name: 'a' * 64 for name in rolling.ASSET_TARGETS}}
        output = '\n'.join('b' * 64 + '  ' + rolling.asset_path('native', name, 'a' * 64)
                           for name in rolling.ASSET_TARGETS)
        with patch.object(rolling.subprocess, 'check_output', return_value=output):
            with self.assertRaises(ValueError):
                rolling.verify_host_assets(config)

    def test_new_release_updates_then_deploys_native_only(self):
        def new(config):
            return 'ghcr.io/org/web:20261023-130000-123abcd', {'SECRET': 'private'}
        self.assertEqual(rolling.reconcile(self.config, self.call, new, True), 'deployed')
        self.assertEqual([w[:2] for w in self.writes], [
            ('PATCH', '/api/v1/applications/native'), ('POST', '/api/v1/deploy?uuid=native')])

    def test_new_release_cannot_copy_development_database_or_send_policy(self):
        self.config['destination_environment'] = [
            'DATABASE_URL', 'DEPLOY_EXPECTED_DATABASE', 'DEPLOY_EXPECTED_ROLE',
            'RELAY_TRANSACTIONAL_DRY_RUN']
        self.env.extend([
            {'key': 'DATABASE_URL', 'value': 'production-database'},
            {'key': 'DEPLOY_EXPECTED_DATABASE', 'value': 'website'},
            {'key': 'DEPLOY_EXPECTED_ROLE', 'value': 'website_app'},
            {'key': 'RELAY_TRANSACTIONAL_DRY_RUN', 'value': '0'},
        ])
        def development(config):
            return 'ghcr.io/org/web:20261023-130000-123abcd', {
                'SECRET': 'private', 'DATABASE_URL': 'development-database',
                'DEPLOY_EXPECTED_DATABASE': 'website_dev', 'DEPLOY_EXPECTED_ROLE': 'website_dev',
                'RELAY_TRANSACTIONAL_DRY_RUN': '1', 'VERSION': 'new-release'}
        self.assertEqual(rolling.reconcile(self.config, self.call, development, True), 'deployed')
        env_write = next(data for method, path, data in self.writes if path.endswith('/envs/bulk'))
        self.assertEqual(env_write['data'], [
            {'key': 'VERSION', 'value': 'new-release', 'is_literal': True,
             'is_runtime': True, 'is_buildtime': False}])
        self.assertEqual(self.writes[-1][1], '/api/v1/deploy?uuid=native')

    def test_missing_destination_secret_blocks_all_promotion_writes(self):
        self.config['destination_environment'] = ['AWS_SECRET_ACCESS_KEY']
        def new(config):
            return 'ghcr.io/org/web:20261023-130000-123abcd', {'AWS_SECRET_ACCESS_KEY': 'source-secret'}
        for record in [None, {'key': 'AWS_SECRET_ACCESS_KEY', 'value': ''},
                       {'key': 'AWS_SECRET_ACCESS_KEY', 'value': 'preview-only', 'is_preview': True},
                       {'key': 'AWS_SECRET_ACCESS_KEY', 'value': 'build-only', 'is_runtime': False}]:
            with self.subTest(record=record):
                self.env = [] if record is None else [record]
                with self.assertRaisesRegex(ValueError, 'Destination environment is incomplete'):
                    rolling.reconcile(self.config, self.call, new, True)
                self.assertEqual(self.writes, [])

    def test_source_tokens_and_relay_identity_never_reach_destination(self):
        self.config['destination_environment'] = ['RELAY_API_KEY', 'RELAY_BASE_URL']
        self.config['destination_environment_optional'] = [
            'AWS_SESSION_TOKEN', 'AWS_SECURITY_TOKEN', 'RELAY_WEBHOOK_SECRET']
        self.env.extend([
            {'key': 'RELAY_API_KEY', 'value': 'production-key', 'is_runtime': True},
            {'key': 'RELAY_BASE_URL', 'value': 'production-relay', 'is_runtime': True}])
        def development(config):
            return 'ghcr.io/org/web:20261023-130000-123abcd', {
                'SECRET': 'private', 'RELAY_API_KEY': 'development-key',
                'RELAY_BASE_URL': 'development-relay', 'AWS_SESSION_TOKEN': 'source-session',
                'AWS_SECURITY_TOKEN': 'source-security', 'RELAY_WEBHOOK_SECRET': 'source-webhook'}
        self.assertEqual(rolling.reconcile(self.config, self.call, development, True), 'deployed')
        self.assertEqual([path for _, path, _ in self.writes], [
            '/api/v1/applications/native', '/api/v1/deploy?uuid=native'])

    def test_git_website_follows_only_the_healthy_source_commit(self):
        config = {**self.config, 'image': 'dtc-website', 'rollout_mode': 'git-commit'}
        self.app.update(build_pack='dockerfile', git_commit_sha='a' * 40)
        state = lambda c: ('dtc-website:' + 'b' * 40, {'SECRET': 'private'})
        self.assertEqual(rolling.reconcile(config, self.call, state, True), 'deployed')
        self.assertEqual(self.writes[0][2], {'git_commit_sha': 'b' * 40})
        self.writes.clear()
        self.assertEqual(rolling.reconcile(config, self.call, state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_git_website_rejects_a_mutable_source_tag(self):
        config = {**self.config, 'image': 'dtc-website', 'rollout_mode': 'git-commit'}
        with self.assertRaises(ValueError):
            rolling.reconcile(config, self.call, lambda c: ('dtc-website:latest', {}), True)
        self.assertEqual(self.writes, [])

    def test_github_run_source_tag_requires_attempt_and_full_commit(self):
        config = {**self.config, 'source_tag_format': 'github-run'}
        pattern = rolling.source_image_tag_pattern(config)
        self.assertRegex('deploy-42835507864-2-' + 'a' * 40, '^' + pattern + '$')
        for tag in ('latest', 'deploy-42835507864-2-abcdef0', 'deploy-main-1-' + 'a' * 40):
            with self.subTest(tag=tag):
                self.assertNotRegex(tag, '^' + pattern + '$')

    def test_timestamped_source_selects_latest_healthy_web(self):
        def container(created, health, image):
            return {'Created': created, 'State': {'Health': {'Status': health}},
                    'Config': {'Image': image, 'Env': ['SECRET=private'],
                               'Entrypoint': ['./entrypoint.sh'], 'Cmd': ['web']}}
        containers = [container('1', 'healthy', 'dtc-website:' + 'a' * 40),
                      container('2', 'starting', 'dtc-website:' + 'b' * 40)]
        config = {'source_uuid': 'source', 'source_container_prefix': 'web-source-', 'ssh_host': 'node'}
        with patch.object(rolling.subprocess, 'check_output', return_value='a' * 12 + '\n' + 'b' * 12), \
                patch.object(rolling.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps(containers))):
            image, env = rolling.source_state(config)
        self.assertEqual(image, 'dtc-website:' + 'a' * 40)
        self.assertEqual(json.loads(env['ROLLING_ORIGINAL_COMMAND']), ['web'])

    def test_failed_compose_source_retains_public_then_follows_healthy_release(self):
        config = {**self.config, 'image': 'dtc-website', 'rollout_mode': 'git-commit',
                  'source_container_prefix': 'web-source-', 'ssh_host': 'node'}
        self.app.update(build_pack='dockerfile', git_commit_sha='a' * 40)
        self.env.extend([{'key': 'ROLLING_ORIGINAL_ENTRYPOINT', 'value': ''},
                         {'key': 'ROLLING_ORIGINAL_COMMAND', 'value': '["web"]'}])
        container = {'Created': '2', 'State': {'Health': {'Status': 'unhealthy'}},
                     'Config': {'Image': 'dtc-website:' + 'b' * 40,
                                'Env': ['SECRET=private'], 'Cmd': ['web']}}
        with patch.object(rolling.subprocess, 'check_output', return_value='b' * 12), \
                patch.object(rolling.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps([container]))):
            try:
                rolling.reconcile(config, self.call, rolling.source_state, True)
            except rolling.SourceUnavailable as error:
                self.assertEqual(rolling.failure_reason(error),
                                 'SourceUnavailable; operation=source_state')
            else:
                self.fail('Unhealthy source was accepted')
        self.assertEqual(self.writes, [])
        container['State']['Health']['Status'] = 'healthy'
        with patch.object(rolling.subprocess, 'check_output', return_value='b' * 12), \
                patch.object(rolling.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps([container]))):
            self.assertEqual(rolling.reconcile(config, self.call, rolling.source_state, True), 'deployed')
            self.writes.clear()
            self.assertEqual(rolling.reconcile(config, self.call, rolling.source_state, True), 'in-sync')
        self.assertEqual(self.writes, [])

    def test_missing_source_is_identified_without_inspecting_other_containers(self):
        config = {**self.config, 'source_container_prefix': 'web-source-', 'ssh_host': 'node'}
        with patch.object(rolling.subprocess, 'check_output', return_value=''), \
                patch.object(rolling.subprocess, 'run') as inspect:
            with self.assertRaises(rolling.SourceUnavailable):
                rolling.reconcile(config, self.call, rolling.source_state, True)
        inspect.assert_not_called()
        self.assertEqual(self.writes, [])

    def test_main_reports_failure_operation_without_exception_values(self):
        config = {'applications': [{'name': 'website'}], 'assets': {},
                  'base': 'local', 'token_file': 'private'}
        stderr = io.StringIO()
        with patch.object(rolling.sys, 'argv', ['follower', '--config', 'config']), \
                patch.object(rolling.Path, 'read_text', side_effect=[json.dumps(config), 'token']), \
                patch.object(rolling, 'verify_control_plane'), \
                patch.object(rolling, 'verify_host_assets'), \
                patch.object(rolling, 'active_rollout', return_value=None), \
                patch.object(rolling, 'reconcile', side_effect=ValueError('secret API body')), \
                redirect_stderr(stderr):
            self.assertEqual(rolling.main(), 1)
        self.assertEqual(stderr.getvalue(),
                         'website: failed (ValueError; operation=main); current public container retained.\n')

    def test_failed_release_is_retried_instead_of_false_convergence(self):
        self.deployments = [{'status': 'failed'}]
        self.assertEqual(rolling.reconcile(self.config, self.call, self.state, True), 'deployed')
        self.assertEqual(self.writes[-1][1], '/api/v1/deploy?uuid=native')

    def test_busy_application_is_not_redeployed(self):
        self.deployments = [{'status': 'in_progress'}]
        self.assertEqual(rolling.reconcile(self.config, self.call, self.state, True), 'busy')
        self.assertEqual(self.writes, [])

    def test_any_active_configured_rollout_blocks_a_new_follower_deploy(self):
        config = {'applications': [{'name': 'aishl', 'app_uuid': 'one'},
                                  {'name': 'relay', 'app_uuid': 'two'}]}
        def call(method, path, data=None):
            return {'deployments': [{'status': 'finished'}] if path.endswith('/one')
                    else [{'status': 'in_progress'}]}
        self.assertEqual(rolling.active_rollout(config, call), 'relay')

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

    def test_environment_rotation_preserves_build_secret_flag(self):
        self.env[0]['is_buildtime'] = True
        state = lambda c: (self.state(c)[0], {'SECRET': 'rotated'})
        rolling.reconcile(self.config, self.call, state, True)
        self.assertTrue(self.writes[0][2]['data'][0]['is_buildtime'])

    def test_proxy_labels_keep_origin_guard_priority_and_healthgate(self):
        labels = rolling.labels_for_web([
            'traefik.http.routers.http-source.rule=Host(`example.test`)',
            'traefik.http.routers.http-source.middlewares=gzip',
            'traefik.http.services.http-source.loadbalancer.server.port=8000',
            'coolify.managed=true'], 'source', 'native', '/ready', health_port=8099)
        self.assertIn('http-native.priority=100', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.path=/ready', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.hostname=localhost', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.interval=5s', labels)
        self.assertIn('http-native.loadbalancer.healthcheck.timeout=3s', labels)
        self.assertIn('http-native.loadbalancer.serverstransport=rolling-web@file', labels)
        self.assertIn('http-native.middlewares=gzip,rolling-retry', labels)
        self.assertNotIn('coolify.managed', labels)

    def test_duplicate_router_services_collapse_and_retry_is_deduplicated(self):
        labels = rolling.labels_for_web([
            'traefik.http.routers.http-source.rule=Host(`example.test`)',
            'traefik.http.routers.http-source.middlewares=gzip,rolling-retry,rolling-retry@docker,rolling-retry',
            'traefik.http.routers.http-source.service=http-source',
            'traefik.http.routers.https-source.rule=Host(`www.example.test`)',
            'traefik.http.routers.https-source.service=https-source',
            'traefik.http.services.http-source.loadbalancer.server.port=8000',
            'traefik.http.services.https-source.loadbalancer.server.port=8000',
        ], 'source', 'native', '/ready', health_port=8099, collapse_services=True)
        self.assertIn('http-native.service=http-native', labels)
        self.assertIn('https-native.service=http-native', labels)
        self.assertEqual(labels.count('.loadbalancer.server.port=8000'), 1)
        router_middlewares = next(line.split('=', 1)[1] for line in labels.splitlines()
                                  if line.startswith('traefik.http.routers.http-native.middlewares='))
        self.assertEqual(router_middlewares.split(',').count('rolling-retry'), 1)

    def test_proxy_labels_add_only_requested_protection_and_preserve_priority(self):
        labels = rolling.labels_for_web([
            'traefik.http.routers.http-source.rule=Host(`example.test`)',
            'traefik.http.routers.http-source.priority=110',
            'traefik.http.routers.http-source.middlewares=gzip',
            'traefik.http.services.http-source.loadbalancer.server.port=8000',
        ], 'source', 'native', '/ready', health_port=8099,
           extra_middlewares=['aishl-rate-limit@file', 'aishl-in-flight@file'])
        self.assertIn('http-native.priority=110', labels)
        self.assertIn('http-native.middlewares=gzip,rolling-retry,aishl-rate-limit@file,aishl-in-flight@file', labels)

    def test_reconcile_updates_proxy_gate_labels_and_direct_docker_liveness(self):
        labels = '\n'.join([
            'traefik.http.routers.http-native.rule=Host(`example.test`)',
            'traefik.http.routers.http-native.middlewares=gzip,rolling-retry,rolling-retry,rolling-retry',
            'traefik.http.services.http-native.loadbalancer.server.port=8000',
            'dtc.rolling-web.application=native',
        ])
        self.app['custom_labels'] = base64.b64encode(labels.encode()).decode()
        self.app['health_check_command'] = 'python /opt/coolify-healthcheck.py http://127.0.0.1:8099/ready'
        config = {**self.config, 'manage_labels': True,
                  'health_check_command': 'python /opt/coolify-healthcheck.py',
                  'proxy_middlewares': ['aishl-rate-limit@file', 'aishl-in-flight@file']}
        self.assertEqual(rolling.reconcile(config, self.call, self.state, True), 'deployed')
        patch = next(data for method, path, data in self.writes if method == 'PATCH' and path == '/api/v1/applications/native')
        decoded = base64.b64decode(patch['custom_labels']).decode()
        router_middlewares = next(line.split('=', 1)[1] for line in decoded.splitlines()
                                  if line.startswith('traefik.http.routers.http-native.middlewares='))
        self.assertEqual(router_middlewares.split(',').count('rolling-retry'), 1)
        self.assertIn('healthcheck.interval=5s', decoded)
        self.assertIn('healthcheck.timeout=3s', decoded)
        self.assertIn('aishl-rate-limit@file', decoded)
        self.assertEqual(patch['health_check_command'], 'python /opt/coolify-healthcheck.py')
        self.assertEqual(self.writes[-1][1], '/api/v1/deploy?uuid=native')

    def test_draining_readiness_port_is_distinct_from_application_port(self):
        labels = rolling.labels_for_web([
            'traefik.http.routers.web-source.rule=Host(`example.test`)',
            'traefik.http.services.web-source.loadbalancer.server.port=8000'],
            'source', 'nativev3', '/ready', health_port=8099,
            application_uuid='native', priority=110)
        self.assertIn('web-nativev3.loadbalancer.server.port=8000', labels)
        self.assertIn('web-nativev3.loadbalancer.healthcheck.port=8099', labels)
        self.assertIn('web-nativev3.priority=110', labels)
        self.assertIn('dtc.rolling-web.application=native', labels)


if __name__ == '__main__':
    unittest.main()
