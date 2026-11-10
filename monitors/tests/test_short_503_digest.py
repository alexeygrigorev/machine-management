import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "contabo-503-digest.py"
spec = importlib.util.spec_from_file_location("contabo_503_digest", MODULE_PATH)
digest = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(digest)


class Short503DigestTests(unittest.TestCase):
    def test_lists_each_short_window_and_omits_two_minute_page_window(self):
        payload = {
            "status": "success",
            "data": {
                "resultType": "matrix",
                "result": [
                    {
                        "metric": {"host": "contabo-a", "router": "shop@docker"},
                        "values": [
                            [1700000000, "4"],
                            [1700000120, "2"],
                            [1700000180, "1"],
                            [1700000240, "1"],
                            [1700000300, "1"],
                        ],
                    }
                ],
            },
        }
        windows = digest.short_windows(payload)
        self.assertEqual(len(windows), 1)
        self.assertEqual([item["duration"] for item in windows], [60])
        rendered = digest.render(payload, start=1700000000, end=1700086400)
        self.assertIn("shop@docker", rendered)
        self.assertIn("1 short window(s)", rendered)

    def test_empty_matrix_reports_no_short_windows(self):
        payload = {"status": "success", "data": {"resultType": "matrix", "result": []}}
        self.assertEqual(digest.short_windows(payload), [])
        self.assertIn("No short 5xx windows", digest.render(payload, start=1, end=2))

    def test_rejects_monitoring_error_response(self):
        with self.assertRaisesRegex(ValueError, "non-success"):
            digest.short_windows({"status": "error", "error": "unavailable"})


if __name__ == "__main__":
    unittest.main()
