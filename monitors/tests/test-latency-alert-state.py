#!/usr/bin/env python3
"""Exercise production latency functions with a controlled clock and offline MTAs."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


MONITORS = Path(__file__).resolve().parents[1]


class LatencyStateTest(unittest.TestCase):
    def run_case(self, script, body):
        source = (MONITORS / script).read_text()
        functions = []
        for name in ("strip_personal_recipients", "enqueue_digest",
                     "send_alert", "send_latency_alert", "probe_latency",
                     "latency_metrics_emit", "latency_metrics_push"):
            match = re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        with tempfile.TemporaryDirectory(prefix="latency-state-") as tmp:
            root = Path(tmp)
            (root / "msmtp").write_text(
                '#!/bin/bash\ncat >> "$MAIL_LOG"\n'
                'printf "%s\\n" "$*" >> "$MAIL_ARGS"\nexit "${MAIL_RC:-0}"\n')
            (root / "msmtp").chmod(0o700)
            harness = r'''
set -euo pipefail
log() { echo "$*"; }
STATE_DIR="$CASE_DIR/state"; mkdir "$STATE_DIR"
# send_alert also uses the configured-host and digest policy helpers.
# Keep the extracted functions isolated from live config and digest spools.
ENV_FILE="$CASE_DIR/env"; touch "$ENV_FILE"
DIGEST_SCRIPT="$CASE_DIR/no-digest-script"
NOW=100000; FAILED=0
ALERT_TO=production@invalid.test
LATENCY_ALERT_TO=latency@invalid.test
ALERT_FROM=alerts@dtcdev.click; ALERT_FROM_NAME='DTC Alerts'
ALERT_MSMTP_ACCOUNT=alerts; ALERT_REPEAT_MIN=60
LATENCY_STATE_SUFFIX=latency; LATENCY_METRICS_FILE=""
LATENCY_TTFB_WARN_SEC=3; LATENCY_TTFB_RECOVER_SEC=2.5; LATENCY_SUSTAIN_SEC=600
HTTP_TIMEOUT=15; HTTP_CONNECT_TIMEOUT=5
curl() { echo "200 ${TTFB:-5.00} 5.20"; }
state_file="$STATE_DIR/latency-p1"
[[ "$SCRIPT_NAME" == coolify-healthcheck.sh ]] && state_file+="-latency"
state_file+=".state"
probe() { FAILED=0; probe_latency p1 https://127.0.0.1/ cmp; }
'''
            env = {**os.environ, "PATH": tmp + ":/usr/bin:/bin", "CASE_DIR": tmp,
                   "MAIL_LOG": tmp + "/mail", "MAIL_ARGS": tmp + "/args",
                   "SCRIPT_NAME": script}
            result = subprocess.run(["bash"], input="\n".join(functions) + harness + body,
                                    text=True, env=env, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def both(self, body):
        for script in ("coolify-healthcheck.sh", "contabo-deadman.sh"):
            with self.subTest(script=script):
                self.run_case(script, body)

    def test_sustain_dedupe_hysteresis_and_recovery(self):
        self.both(r'''
probe; [[ ! -s "$MAIL_LOG" ]]
NOW=100599; probe; [[ ! -s "$MAIL_LOG" ]]
NOW=100600; probe; [[ "$FAILED" == 1 ]]
[[ $(grep -c '^Subject:.* FAIL ' "$MAIL_LOG") == 1 ]]
[[ $(grep -c '^To: latency@invalid.test$' "$MAIL_LOG") == 1 ]]
grep -q -- '-f alerts@dtcdev.click -- latency@invalid.test' "$MAIL_ARGS"
! grep -q production@invalid.test "$MAIL_LOG"
NOW=104199; probe
[[ $(grep -c '^Subject:.* FAIL ' "$MAIL_LOG") == 1 ]]
NOW=104200; probe
[[ $(grep -c '^Subject:.* FAIL ' "$MAIL_LOG") == 2 ]]
TTFB=2.7; probe; [[ "$FAILED" == 1 ]]
grep -q '^STATUS=FAIL$' "$state_file"
TTFB=2.5; probe; grep -q '^STATUS=FAIL$' "$state_file"
TTFB=2.4; probe; grep -q '^STATUS=OK$' "$state_file"
[[ $(grep -c '^Subject:.* RECOVERED ' "$MAIL_LOG") == 1 ]]
probe; [[ $(grep -c '^Subject:' "$MAIL_LOG") == 3 ]]
''')

    def test_failed_fail_retries_without_dedupe(self):
        self.both(r'''
probe; NOW=100600
export MAIL_RC=1; probe
grep -q '^LAST_ALERT=0$' "$state_file"
grep -q '^FIRST_EXCEED=100000$' "$state_file"
export MAIL_RC=0; NOW=100601; probe
grep -q '^LAST_ALERT=100601$' "$state_file"
[[ $(grep -c '^Subject:.* FAIL ' "$MAIL_LOG") == 2 ]]
''')

    def test_failed_recovery_retries_before_clearing_state(self):
        self.both(r'''
probe; NOW=100600; probe
TTFB=0.2; export MAIL_RC=1; NOW=100601; probe
[[ "$FAILED" == 1 ]]; grep -q '^STATUS=FAIL$' "$state_file"
grep -q '^FIRST_EXCEED=100000$' "$state_file"
export MAIL_RC=0; NOW=100602; probe
grep -q '^STATUS=OK$' "$state_file"
[[ $(grep -c '^Subject:.* RECOVERED ' "$MAIL_LOG") == 2 ]]
probe; [[ $(grep -c '^Subject:' "$MAIL_LOG") == 3 ]]
''')

    def test_probe_state_does_not_leak(self):
        self.both(r'''
probe; NOW=100600; probe
probe_latency p2 https://127.0.0.1/ cmp
p2="${state_file/p1/p2}"
grep -q '^LAST_ALERT=0$' "$p2"
grep -q '^FIRST_EXCEED=100600$' "$p2"
''')

    def test_healthy_sample_resets_pending_sustain(self):
        self.both(r'''
probe; NOW=100599; TTFB=2.7; probe
NOW=100600; TTFB=5; probe; [[ ! -s "$MAIL_LOG" ]]
NOW=101199; probe; [[ ! -s "$MAIL_LOG" ]]
NOW=101200; probe; [[ $(grep -c '^Subject:' "$MAIL_LOG") == 1 ]]
''')

    def test_http_ingestion_failure_is_not_success(self):
        self.both(r'''
curl() {
  # Model curl's HTTP 500 behavior: failure only when --fail/-f is supplied.
  [[ " $* " == *" -fsS "* ]] && return 22
  return 0
}
LATENCY_PUSH_ENABLED=1; LATENCY_PUSH_TIMEOUT=1; LATENCY_PUSH_SSH_HOST=""
LATENCY_PUSH_URL=http://127.0.0.1:8429/api/v1/import/prometheus
LATENCY_METRICS_FILE="$CASE_DIR/metrics"; echo probe_ttfb_seconds\ 5 > "$LATENCY_METRICS_FILE"
latency_metrics_push > "$CASE_DIR/push-log"
grep -q 'WARN latency-push' "$CASE_DIR/push-log"
! grep -q 'OK latency-push' "$CASE_DIR/push-log"
''')


if __name__ == "__main__":
    unittest.main()
