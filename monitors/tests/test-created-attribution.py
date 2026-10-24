"""Exercise the actual healthcheck function without alert transport or Docker."""
import pathlib
import subprocess
import unittest


class AttributionTest(unittest.TestCase):
    def test_unknown_and_stale_metadata_in_log_and_alert(self):
        script = (pathlib.Path(__file__).parents[1] / 'coolify-healthcheck.sh').read_text()
        function = script[script.index('check_created_containers() {'):script.index('# ---- run ----')]
        for created in ('not-a-date', '2020-01-01T00:00:00Z'):
            stub = '''
log() { echo "LOG $*"; }
send_alert() { echo "ALERT $*"; }
mark_ok() { echo OK; }
docker() {
 if [[ "$1" == ps ]]; then echo abc123; return; fi
 if [[ "$3" == '{{.Created}}' ]]; then echo CREATED_DATE; return; fi
 echo 'name=/test image=alpine:3.22 agent.session=session-123 coolify.app=app-456 coolify.resourceName=app coolify.managed=true'
}
'''.replace('CREATED_DATE', created)
            out = subprocess.check_output(['bash', '-c', stub + function + '\ncheck_created_containers'], text=True)
            for line in out.splitlines():
                if line.startswith(('LOG FAIL', 'ALERT')):
                    for value in ('abc123', 'name=/test', 'image=alpine:3.22', 'agent.session=session-123', 'coolify.app=app-456'):
                        self.assertIn(value, line)
            self.assertIn('LOG FAIL', out)
            self.assertIn('ALERT', out)
            self.assertNotIn('a Coolify deploy created', out)


if __name__ == '__main__':
    unittest.main()
