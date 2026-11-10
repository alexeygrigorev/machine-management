import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "traefik" / "patch-aisl-dev-route.py"
spec = importlib.util.spec_from_file_location("patch_aisl_dev_route", MODULE_PATH)
patcher = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(patcher)


ROUTE = """http:
  routers:
    aisl-dev-https:
      rule: Host(`dev.aishippinglabs.com`)
      entryPoints:
        - https
      service: aisl-dev-source-web
      tls:
        certResolver: letsencrypt
    aisl-dev-http:
      rule: Host(`dev.aishippinglabs.com`)
      entryPoints:
        - http
      middlewares:
        - aisl-dev-redirect-https
      service: aisl-dev-source-web
  middlewares:
    aisl-dev-redirect-https:
      redirectScheme:
        scheme: https
        permanent: true
  services:
    aisl-dev-source-web:
      loadBalancer:
        servers:
          - url: http://web-dynamic-name:8000
"""


class AislDevRouteTests(unittest.TestCase):
    def test_adds_guard_without_replacing_dynamic_service_or_http_redirect(self):
        patched = patcher.patch_route(ROUTE)
        self.assertIn("        - aishl-rate-limit\n        - aishl-in-flight\n      service: aisl-dev-source-web", patched)
        self.assertIn("- aisl-dev-redirect-https", patched)
        self.assertIn("http://web-dynamic-name:8000", patched)

    def test_is_idempotent(self):
        patched = patcher.patch_route(ROUTE)
        self.assertEqual(patcher.patch_route(patched), patched)

    def test_refuses_missing_or_wrong_router(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            patcher.patch_route("http:\n  routers: {}\n")
        with self.assertRaisesRegex(ValueError, "does not route"):
            patcher.patch_route(ROUTE.replace("dev.aishippinglabs.com", "other.example"))


if __name__ == "__main__":
    unittest.main()
