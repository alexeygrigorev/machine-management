"""The escrow CLI must fail before reading ciphertext outside sandbox."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('escrow_value', ROOT / 'team-secret-value.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AccountBoundary(unittest.TestCase):
    def test_wrong_account_never_reads_the_store(self):
        session = Mock()
        session.client.return_value.get_caller_identity.return_value = {'Account': '000000000000'}
        with patch.object(module.boto3, 'Session', return_value=session) as factory, \
                patch.object(sys, 'argv', ['reader', 'dr-escrow.acme-backup-gpg-passphrase']), \
                patch.object(module, 'SecretReader') as reader:
            with self.assertRaisesRegex(RuntimeError, 'Sandbox account required'):
                module.main()
            factory.assert_called_once_with(profile_name='default', region_name='eu-west-1')
            session.client.assert_called_once_with('sts')
            reader.assert_not_called()

    def test_pipe_preserves_bytes_without_extra_newline(self):
        session = Mock()
        session.client.return_value.get_caller_identity.return_value = {'Account': '817685572750'}
        reader = Mock()
        reader.read.return_value = {'value': 'fixture-passphrase'}
        output = io.StringIO()
        with patch.object(module.boto3, 'Session', return_value=session), \
                patch.object(sys, 'argv', ['reader', 'dr-escrow.acme-backup-gpg-passphrase']), \
                patch.object(module, 'SecretReader', return_value=reader), contextlib.redirect_stdout(output):
            module.main()
        reader.read.assert_called_once_with('dr-escrow.acme-backup-gpg-passphrase')
        self.assertEqual(output.getvalue(), 'fixture-passphrase')


if __name__ == '__main__':
    unittest.main()
