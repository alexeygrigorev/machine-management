import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import origin_transport as transport


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.scope = transport.ORIGINS[0]
        self.header = "synthetic-test-value-123456"
        self.config = {
            "Aliases": {"Items": [self.scope.viewer]},
            "Comment": "preserve unrelated settings",
            "Origins": {"Items": [
                {"Id": self.scope.origin_id, "DomainName": self.scope.domain,
                 "CustomOriginConfig": {"OriginProtocolPolicy": "http-only", "HTTPSPort": 443},
                 "CustomHeaders": {"Items": [{"HeaderName": "x-origin-verify", "HeaderValue": self.header}]}},
                {"Id": "unrelated", "CustomOriginConfig": {"OriginProtocolPolicy": "http-only"}},
            ]},
        }
        self.snapshot = {"ETag": "initial", "Distribution": {
            "Status": "Deployed", "DistributionConfig": self.config}}

    def test_only_target_transport_changes(self):
        original = copy.deepcopy(self.config)
        patched = transport.patch_config(self.config, self.scope.origin_id, "https-only")
        self.assertEqual(self.config, original)
        patched["Origins"]["Items"][0]["CustomOriginConfig"]["OriginProtocolPolicy"] = "http-only"
        self.assertEqual(patched, original)

    def test_rejects_domain_port_alias_and_header_drift(self):
        for change in ("domain", "port", "alias", "header"):
            with self.subTest(change=change):
                snapshot = copy.deepcopy(self.snapshot)
                cfg = snapshot["Distribution"]["DistributionConfig"]
                origin = cfg["Origins"]["Items"][0]
                if change == "domain": origin["DomainName"] = "unrelated.invalid"
                if change == "port": origin["CustomOriginConfig"]["HTTPSPort"] = 444
                if change == "alias": cfg["Aliases"]["Items"] = []
                if change == "header": origin["CustomHeaders"]["Items"][0]["HeaderValue"] = "bad\nheader"
                with self.assertRaises(transport.Refused):
                    transport.config_origin(snapshot, self.scope)

    def test_certificate_failure_refuses_without_mutation(self):
        invalid_cert = subprocess.CompletedProcess([], 60, "000", "private diagnostic")
        with patch.object(transport, "aws", return_value=self.snapshot), \
                patch.object(transport.subprocess, "run", return_value=invalid_cert) as run:
            with self.assertRaisesRegex(transport.Refused, "certificate validation failed"):
                transport.flip(self.scope, "https-only")
        self.assertFalse(any("update-distribution" in c.args[0] for c in run.call_args_list))

    def test_probe_uses_trusted_sni_and_keeps_header_out_of_argv(self):
        with patch.object(transport.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "200", "")) as run:
            self.assertEqual(transport.probe(self.scope, self.scope.viewer, header=self.header), "200")
        args = run.call_args.args[0]
        self.assertEqual(args[1], "--disable")  # Ignore .curlrc, including insecure/debug options.
        self.assertNotIn("-k", args)
        self.assertNotIn("--insecure", args)
        self.assertIn(f"{self.scope.viewer}:443:{self.scope.ip}", args)
        self.assertNotIn(self.header, " ".join(args))
        self.assertIn(self.header, run.call_args.kwargs["input"])

    def test_viewer_sni_and_wrong_header_are_required(self):
        def result(scope, hostname, scheme="https", header=None):
            if hostname == scope.viewer and scheme == "https" and header == self.header:
                return "503"
            return "200" if header == self.header else "403"
        with patch.object(transport, "probe", side_effect=result) as probe:
            with self.assertRaisesRegex(transport.Refused, "authenticated readiness"):
                transport.readiness(self.scope, self.header)
        self.assertTrue(any(c.args[1] == self.scope.viewer for c in probe.call_args_list))
        self.assertTrue(any(c.args[3] == "invalid-origin-verification-value" for c in probe.call_args_list))
        with patch.object(transport, "probe", return_value="200"):
            with self.assertRaisesRegex(transport.Refused, "not denied"):
                transport.readiness(self.scope, self.header)

    def test_etag_race_refuses_before_update(self):
        latest = dict(self.snapshot, ETag="changed")
        with patch.object(transport, "aws", side_effect=[self.snapshot, latest]), \
                patch.object(transport, "readiness"), patch.object(transport, "probe", return_value="200"), \
                patch("builtins.input", return_value="YES"), patch.object(transport.subprocess, "run") as run:
            with self.assertRaisesRegex(transport.Refused, "distribution changed"):
                transport.flip(self.scope, "https-only")
        run.assert_not_called()

    def test_success_uses_original_etag_and_stdin_and_checks_public_health(self):
        deployed = copy.deepcopy(self.snapshot)
        deployed["Distribution"]["DistributionConfig"] = transport.patch_config(self.config, self.scope.origin_id, "https-only")
        output = io.StringIO()
        with patch.object(transport, "aws", side_effect=[self.snapshot, self.snapshot, deployed]), \
                patch.object(transport, "readiness"), patch.object(transport, "probe", return_value="200") as probe, \
                patch("builtins.input", return_value="YES"), \
                patch.object(transport.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")) as run, \
                redirect_stdout(output):
            transport.flip(self.scope, "https-only")
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("--if-match") + 1], "initial")
        self.assertIn("file:///dev/stdin", args)
        cfg = json.loads(run.call_args.kwargs["input"])
        self.assertEqual(cfg, deployed["Distribution"]["DistributionConfig"])
        self.assertNotIn(self.header, str(args) + output.getvalue())
        self.assertEqual(probe.call_count, 2)

    def test_noop_does_not_request_update(self):
        with patch.object(transport, "aws", return_value=self.snapshot) as aws, \
                patch.object(transport.subprocess, "run") as run:
            transport.flip(self.scope, "http-only")
        self.assertEqual(aws.call_count, 1)
        run.assert_not_called()

    def test_aws_defaults_to_default_profile_never_main_temp(self):
        with patch.dict(transport.os.environ, {}, clear=True), \
                patch.object(transport.subprocess, "run",
                             return_value=subprocess.CompletedProcess([], 0, "{}", "")) as run:
            transport.aws("cloudfront", "get-distribution", "--id", "E33FS79KPFSAOM")
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("--profile") + 1], "default")
        self.assertNotIn("main-temp", args)

    def test_verify_origin_falls_back_to_ssh_header_when_cloudfront_unavailable(self):
        import verify_origin
        with patch.object(verify_origin, "aws", side_effect=transport.Refused("NoSuchDistribution")), \
                patch.object(verify_origin, "ssh", return_value=self.header), \
                patch.dict(verify_origin.SNAPSHOT_FALLBACK, {}, clear=True):
            protocol, hdr = verify_origin.origin_state(self.scope)
        self.assertEqual(protocol, "https-only")
        self.assertEqual(hdr, self.header)


if __name__ == "__main__":
    unittest.main()
