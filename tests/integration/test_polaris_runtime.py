import json
import os
import pathlib
import subprocess
import urllib.request
import urllib.error
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = os.getenv("POLARIS_URL", "http://127.0.0.1:8181")
HEALTH = os.getenv("POLARIS_HEALTH_URL", "http://127.0.0.1:8182/q/health")


def get_json(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status, json.loads(response.read().decode())


class PolarisRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["docker", "compose", "config", "-q"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise unittest.SkipTest(f"Docker Compose configuration is invalid: {result.stderr}")

    def test_compose_config_is_valid(self):
        result = subprocess.run(
            ["docker", "compose", "config", "-q"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_health_endpoint(self):
        status, body = get_json(HEALTH)
        self.assertEqual(status, 200)
        self.assertEqual(body.get("status"), "UP")

    def test_oauth_realm_token(self):
        client_id = os.getenv("POLARIS_ROOT_CLIENT_ID")
        client_secret = os.getenv("POLARIS_ROOT_CLIENT_SECRET")
        realm = os.getenv("POLARIS_REALM", "ISBUS")
        if not client_id or not client_secret:
            self.skipTest("Set POLARIS_ROOT_CLIENT_ID and POLARIS_ROOT_CLIENT_SECRET")

        data = (
            "grant_type=client_credentials"
            f"&client_id={client_id}"
            f"&client_secret={client_secret}"
            "&scope=PRINCIPAL_ROLE:ALL"
        ).encode()
        request = urllib.request.Request(
            f"{BASE}/api/catalog/v1/oauth/tokens",
            data=data,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Polaris-Realm": realm,
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            body = json.loads(response.read().decode())
        self.assertTrue(body.get("access_token"))

    def test_catalog_management_requires_authentication(self):
        try:
            get_json(f"{BASE}/api/management/v1/catalogs")
        except urllib.error.HTTPError as error:
            self.assertIn(error.code, (401, 403))
        else:
            self.fail("Unauthenticated management request unexpectedly succeeded")


if __name__ == "__main__":
    unittest.main()
