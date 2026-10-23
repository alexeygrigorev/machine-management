import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_stability as stability
from origin_transport import ORIGINS, Refused


class StabilityTests(unittest.TestCase):
    def measure(self, responses):
        evidence = {"accepted": False}
        checks = [("public", ORIGINS[0], True, None, "/health/ready", "200")]
        with patch.object(stability, "probe", side_effect=responses) as probe, \
                patch.object(stability.time, "sleep"), redirect_stdout(io.StringIO()):
            result = stability.measure(checks, len(responses), 5, evidence)
        return result, evidence, probe

    def test_transient_failure_is_not_erased_by_recovery(self):
        passed, evidence, probe = self.measure(["200", "503", "200"])
        self.assertFalse(passed)
        self.assertEqual(evidence["summary"]["public"], {"200": 2, "503": 1})
        self.assertEqual(probe.call_count, 3)  # No retries that hide the failure.
        paths = [call.kwargs["path"] for call in probe.call_args_list]
        self.assertEqual(len(set(paths)), 3)
        self.assertTrue(all("?origin_stability=" in path for path in paths))

    def test_connection_failure_is_retained_without_diagnostics(self):
        for error in (Refused("private-diagnostic"), subprocess.TimeoutExpired("private-diagnostic", 15)):
            with self.subTest(error=type(error).__name__):
                passed, evidence, _ = self.measure([error, "200"])
                self.assertFalse(passed)
                self.assertEqual(evidence["samples"][0]["status"], "connection-or-tls-error")
                self.assertNotIn("private-diagnostic", str(evidence))

    def test_interruption_preserves_failed_partial_evidence(self):
        checks = [("public", ORIGINS[0], True, None, "/", "200")]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "samples.json"
            with patch.object(sys, "argv", ["verify_stability.py", "--rounds", "2", "--output", str(output)]), \
                    patch.object(stability, "targets", return_value=checks), \
                    patch.object(stability, "probe", side_effect=["503", KeyboardInterrupt]), \
                    patch.object(stability.time, "sleep"), redirect_stdout(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    stability.main()
            evidence = json.loads(output.read_text())
            self.assertFalse(evidence["accepted"])
            self.assertEqual(evidence["samples"][0]["status"], "503")
            with patch.object(sys, "argv", ["verify_stability.py", "--output", str(output)]), \
                    patch.object(stability, "targets") as targets:
                with self.assertRaises(FileExistsError):
                    stability.main()
            targets.assert_not_called()

    def test_healthy_and_denied_traffic_pass_without_serializing_credential(self):
        evidence = {"accepted": False}
        checks = [
            ("authenticated", ORIGINS[0], False, "synthetic-secret", "/health/ready", "200"),
            ("missing", ORIGINS[0], False, None, "/health/ready", "403"),
        ]
        with patch.object(stability, "probe", side_effect=["200", "403"]), \
                redirect_stdout(io.StringIO()) as output:
            self.assertTrue(stability.measure(checks, 1, 5, evidence))
        self.assertNotIn("synthetic-secret", str(evidence) + output.getvalue())
        self.assertEqual(len(evidence["samples"]), 2)


if __name__ == "__main__":
    unittest.main()
