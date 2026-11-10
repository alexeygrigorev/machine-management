import importlib.util
from pathlib import Path
import unittest
import io
import json
import tempfile
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).parents[1] / 'verify-coolify-rolling.py')
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceTests(unittest.TestCase):
    def test_docker29_actor_id_is_retained_without_attributes(self):
        raw = {'Actor': {'ID': 'container-id', 'Attributes': {'secret': 'private'}},
               'Action': 'start', 'timeNano': 1}
        process = SimpleNamespace(stdout=io.StringIO(json.dumps(raw) + '\n'))
        events = []
        with tempfile.TemporaryDirectory() as directory:
            acceptance.collect_events(process, events, Path(directory) / 'events.jsonl')
        self.assertEqual(events, [{'id': 'container-id', 'Action': 'start', 'timeNano': 1}])

    def events(self, healthy=2, drained=3, killed=20):
        return [
            {'id': 'new', 'Action': 'start', 'timeNano': 1_000_000_000},
            {'id': 'new', 'Action': 'health_status: healthy', 'timeNano': healthy * 1_000_000_000},
            {'id': 'old', 'Action': 'exec_start: python /opt/rolling-readiness.py drain', 'timeNano': drained * 1_000_000_000},
            {'id': 'old', 'Action': 'kill', 'timeNano': killed * 1_000_000_000},
        ]

    def test_healthy_before_drain_with_propagation_passes(self):
        result = acceptance.lifecycle(self.events(), 'old', 'new')
        self.assertLess(result['new_healthy'], result['old_drained'])
        self.assertLess(result['old_drained'], result['old_killed'])

    def test_kill_old_first_cannot_be_accepted(self):
        with self.assertRaises(ValueError):
            acceptance.lifecycle(self.events(healthy=20), 'old', 'new')

    def test_insufficient_proxy_withdrawal_cannot_be_accepted(self):
        with self.assertRaises(ValueError):
            acceptance.lifecycle(self.events(killed=17), 'old', 'new')

    def test_missing_drain_proof_cannot_be_accepted(self):
        events = [e for e in self.events() if not e['Action'].startswith('exec_start')]
        with self.assertRaises(ValueError):
            acceptance.lifecycle(events, 'old', 'new')

    def test_other_container_health_does_not_prove_replacement_ready(self):
        events = self.events()
        events[1]['id'] = 'unrelated'
        with self.assertRaises(ValueError):
            acceptance.lifecycle(events, 'old', 'new')
