"""Run the real monitor with a fake database; never send mail or touch production."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CallbackHealthcheckTests(unittest.TestCase):
    def run_check(self, counts, db_rc=0, enabled=True):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            tmp = Path(directory)
            docker = tmp / 'docker'
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$COUNTS"\nexit "$DB_RC"\n')
            docker.chmod(0o755)
            mail = tmp / 'sendmail'
            mail.write_text('#!/bin/sh\ncat >> "$MAIL_FILE"\n')
            mail.chmod(0o755)
            msmtp = tmp / 'msmtp'
            msmtp.write_text('#!/bin/sh\ncat >> "$MAIL_FILE"\n')
            msmtp.chmod(0o755)
            datamailer = tmp / 'datamailer'
            datamailer.write_text('''#!/bin/bash
set -euo pipefail
args="$*"; from=""; to=""; subject=""
while (($#)); do
  case "$1" in
    --from) from="$2"; shift 2 ;;
    --to) to="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$from" == alerts ]]
{
  echo 'From: DTC Alerts <alerts@dtcdev.click>'
  echo "To: $to"
  echo "Subject: $subject"
  echo
  cat
} >> "$MAIL_FILE"
printf '%s\\n' "$args" >> "$MAIL_ARGS"
''')
            datamailer.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:/usr/bin:/bin',
                       DATAMAILER_BIN=str(datamailer),
                       RELAY_MONITOR_CONFIG=str(tmp / 'relay.toml'),
                       COOLIFY_HEALTHCHECK_ENV_FILE=str(tmp / 'absent'),
                       STATE_DIR=str(tmp / 'state'), LOCK_FILE=str(tmp / 'lock'),
                       PG_SHARED_CONTAINER='shared', PG_RELAY_CONTAINER='relay',
                       SKIP_PG_SHARED='1', SKIP_PG_RELAY='1', SKIP_DISK_CHECK='1',
                       SKIP_BACKUP_CHECKS='1', SKIP_CREATED_CHECK='1',
                       SKIP_PUBLIC_HTTP_CHECKS='1', LATENCY_PROBES='', LATENCY_PUSH_ENABLED='0',
                       APP_URLS='', CONTENT_CHECKS='',
                       CHECK_CMP_CALLBACKS='1' if enabled else '0',
                       ALERT_TO='dev@dtcdev.click', ALERT_OPS_TO='dev@dtcdev.click',
                       COUNTS=counts, DB_RC=str(db_rc), MAIL_FILE=str(tmp / 'mail'),
                       MAIL_ARGS=str(tmp / 'mail-args'))
            result = subprocess.run(['bash', str(ROOT / 'monitors/coolify-healthcheck.sh')],
                                    env=env, capture_output=True, text=True)
            mails = (tmp / 'mail').read_text() if (tmp / 'mail').exists() else ''
            return result.returncode, result.stdout, mails

    def test_incident_old_pending_alerts(self):
        rc, out, mail = self.run_check('147|0')
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL check=cmp-callbacks', out)
        self.assertIn('From: DTC Alerts <alerts@dtcdev.click>', mail)
        self.assertIn('pending_older_30m=147', mail)

    def test_recent_failed_alerts(self):
        rc, out, mail = self.run_check('0|3')
        self.assertEqual(rc, 1, out)
        self.assertIn('failed_last_24h=3', mail)

    def test_recovered_queue_passes(self):
        rc, out, _ = self.run_check('0|0')
        self.assertEqual(rc, 0, out)
        self.assertIn('OK check=cmp-callbacks', out)

    def test_query_failure_is_not_healthy_and_does_not_log_raw_output(self):
        rc, out, mail = self.run_check('sensitive database error', 2)
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL check=cmp-callbacks', out)
        self.assertNotIn('sensitive database error', out + mail)

    def test_malformed_result_fails_closed(self):
        rc, out, _ = self.run_check('')
        self.assertEqual(rc, 1, out)

    def test_explicitly_disabled_skips(self):
        rc, out, _ = self.run_check('147|0', enabled=False)
        self.assertEqual(rc, 0, out)
        self.assertNotIn('FAIL check=cmp-callbacks', out)


if __name__ == '__main__':
    unittest.main()
