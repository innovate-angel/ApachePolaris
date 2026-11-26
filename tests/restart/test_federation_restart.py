"""Restart test for the federated catalog.

Polaris 1.9.0 keeps a federated catalog's client secret in memory only, so a
restart breaks the catalog until scripts/setup-tableflow-federation.sh
recreates it. This test starts an isolated copy of the Compose stack (its own
project, volume, and loopback ports), federates Polaris to a catalog it serves
itself as a stand-in for Tableflow, and checks that the setup script restores
the connection and keeps catalog roles, grants, and assignments.

Needs Docker and the pinned images; no Azure or Confluent access.
"""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[2]
PORT = int(os.getenv("POLARIS_TEST_PORT", "18181"))
BASE = f"http://localhost:{PORT}"
MGMT = f"{BASE}/api/management/v1"
REALM = "ISBUS"
ADMIN_ID = "restart-test-admin"
ADMIN_SECRET = "restart-test-admin-secret"
CATALOG = "tableflow"
SETUP = str(ROOT / "scripts" / "setup-tableflow-federation.sh")

# Catalog roles an operator would add for query engines; they must survive.
OPERATOR_ROLE = "engine_read_only"
OPERATOR_GRANTS = ["NAMESPACE_LIST", "TABLE_LIST", "TABLE_READ_DATA"]
OPERATOR_PRINCIPAL_ROLE = "engine_readers"


def call(method, url, body=None, token=None):
    headers = {"Polaris-Realm": REALM}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode()
            return response.status, json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        with error:
            return error.code, error.read().decode()


class FederationRestartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
            raise unittest.SkipTest("Docker is not available")

        cls.state_dir = tempfile.mkdtemp(prefix="polaris-restart-test-")
        cls.addClassCleanup(shutil.rmtree, cls.state_dir, ignore_errors=True)
        passthrough = ("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG", "DOCKER_CONTEXT", "XDG_RUNTIME_DIR")
        cls.env = {name: os.environ[name] for name in passthrough if name in os.environ}
        cls.env.update(
            COMPOSE_PROJECT_NAME="polaris-restart-test",
            COMPOSE_FILE="docker-compose.yml:tests/restart/compose.override.yml",
            COMPOSE_DISABLE_ENV_FILE="1",
            POLARIS_TEST_PORT=str(PORT),
            POLARIS_BIND_ADDRESS="127.0.0.1",  # interpolated by the base file; ports are overridden
            POLARIS_TEST_MGMT_PORT=str(PORT + 1),
            POLARIS_URL=BASE,
            POLARIS_STATE_DIR=cls.state_dir,
            POLARIS_REALM=REALM,
            POLARIS_ROOT_CLIENT_ID=ADMIN_ID,
            POLARIS_ROOT_CLIENT_SECRET=ADMIN_SECRET,
            POLARIS_TOKEN_BROKER_SECRET="cmVzdGFydC10ZXN0LXRva2VuLWJyb2tlci1zZWNyZXQtMDEyMzQ1Njc4OQ==",
            POSTGRES_PASSWORD="restart-test-postgres",
            AZURE_TENANT_ID="00000000-0000-0000-0000-000000000000",
            AZURE_STORAGE_ACCOUNT="restarttest",
            AZURE_STORAGE_CONTAINER="tableflow",
            # Stand-in for Tableflow: the "remote" catalog served by this Polaris.
            TABLEFLOW_PROXY_BASE_URL=BASE,
            TABLEFLOW_ORG_ID="test",
            TABLEFLOW_ENV_ID="test",
            TABLEFLOW_CATALOG_URI=f"{BASE}/api/catalog",
            TABLEFLOW_TOKEN_URI=f"{BASE}/api/catalog/v1/oauth/tokens",
            TABLEFLOW_API_KEY=ADMIN_ID,
            TABLEFLOW_API_SECRET=ADMIN_SECRET,
            TABLEFLOW_OAUTH_SCOPE="PRINCIPAL_ROLE:ALL",
            TABLEFLOW_REMOTE_CATALOG_NAME="remote",
        )

        cls.compose("down", "-v")
        cls.addClassCleanup(cls.compose, "down", "-v")
        cls.compose("up", "-d", "postgres")
        cls.run_checked([str(ROOT / "scripts" / "bootstrap.sh")])
        cls.compose("up", "-d", "--wait", "polaris")

        cls.create_remote_catalog()
        cls.run_checked([SETUP])

        token = cls.token()
        cls.expect(call("POST", f"{MGMT}/principal-roles", {"principalRole": {"name": OPERATOR_PRINCIPAL_ROLE}}, token))
        cls.expect(call(
            "POST", f"{MGMT}/catalogs/{CATALOG}/catalog-roles",
            {"catalogRole": {"name": OPERATOR_ROLE, "properties": {"owner": "data-platform"}}}, token,
        ))
        for privilege in OPERATOR_GRANTS:
            cls.expect(call(
                "PUT", f"{MGMT}/catalogs/{CATALOG}/catalog-roles/{OPERATOR_ROLE}/grants",
                {"grant": {"type": "catalog", "privilege": privilege}}, token,
            ))
        cls.expect(call(
            "PUT", f"{MGMT}/principal-roles/{OPERATOR_PRINCIPAL_ROLE}/catalog-roles/{CATALOG}",
            {"catalogRole": {"name": OPERATOR_ROLE}}, token,
        ))

    @classmethod
    def run_checked(cls, command, **env):
        result = subprocess.run(command, cwd=ROOT, env={**cls.env, **env}, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"{command} failed ({result.returncode}):\n{result.stdout}{result.stderr}")
        return result

    @classmethod
    def compose(cls, *args):
        return cls.run_checked(["docker", "compose", *args])

    @staticmethod
    def expect(response):
        status, body = response
        if not 200 <= status < 300:
            raise AssertionError(f"HTTP {status}: {body}")
        return body

    @classmethod
    def token(cls):
        data = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": ADMIN_ID,
            "client_secret": ADMIN_SECRET,
            "scope": "PRINCIPAL_ROLE:ALL",
        }).encode()
        request = urllib.request.Request(
            f"{BASE}/api/catalog/v1/oauth/tokens", data=data, headers={"Polaris-Realm": REALM}, method="POST"
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode())["access_token"]

    @classmethod
    def create_remote_catalog(cls):
        token = cls.token()
        location = "abfss://remote@restarttest.dfs.core.windows.net/"
        cls.expect(call("POST", f"{MGMT}/catalogs", {"catalog": {
            "type": "INTERNAL",
            "name": "remote",
            "properties": {"default-base-location": location},
            "storageConfigInfo": {
                "storageType": "AZURE",
                "tenantId": "00000000-0000-0000-0000-000000000000",
                "allowedLocations": [location],
            },
        }}, token))
        cls.expect(call("POST", f"{MGMT}/catalogs/remote/catalog-roles", {"catalogRole": {"name": "remote_content"}}, token))
        cls.expect(call(
            "PUT", f"{MGMT}/catalogs/remote/catalog-roles/remote_content/grants",
            {"grant": {"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}}, token,
        ))
        cls.expect(call(
            "PUT", f"{MGMT}/principal-roles/service_admin/catalog-roles/remote",
            {"catalogRole": {"name": "remote_content"}}, token,
        ))
        cls.expect(call("POST", f"{BASE}/api/catalog/v1/remote/namespaces", {"namespace": ["lkc-test"]}, token))

    def restart_polaris(self):
        self.compose("restart", "polaris")
        self.compose("up", "-d", "--wait", "polaris")

    def federated_namespaces(self):
        return call("GET", f"{BASE}/api/catalog/v1/{CATALOG}/namespaces", token=self.token())

    def catalog_rbac(self):
        token = self.token()
        roles = self.expect(call("GET", f"{MGMT}/catalogs/{CATALOG}/catalog-roles", token=token))["roles"]
        rbac = {}
        for role in roles:
            name = role["name"]
            grants = self.expect(call("GET", f"{MGMT}/catalogs/{CATALOG}/catalog-roles/{name}/grants", token=token))
            assignees = self.expect(call("GET", f"{MGMT}/catalogs/{CATALOG}/catalog-roles/{name}/principal-roles", token=token))
            rbac[name] = {
                "properties": role["properties"],
                "privileges": sorted(grant["privilege"] for grant in grants["grants"]),
                "principal_roles": sorted(item["name"] for item in assignees["roles"]),
            }
        return rbac

    def assert_operator_rbac_intact(self):
        rbac = self.catalog_rbac()
        self.assertEqual(rbac[OPERATOR_ROLE], {
            "properties": {"owner": "data-platform"},
            "privileges": OPERATOR_GRANTS,
            "principal_roles": [OPERATOR_PRINCIPAL_ROLE],
        })
        self.assertEqual(rbac["tableflow_reader"]["privileges"], ["CATALOG_MANAGE_CONTENT"])
        self.assertEqual(rbac["tableflow_reader"]["principal_roles"], ["service_admin"])
        self.assertEqual(rbac["catalog_admin"]["principal_roles"], ["service_admin"])

    def assert_federation_works(self):
        status, body = self.federated_namespaces()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["namespaces"], [["lkc-test"]])

    def assert_no_journal(self):
        self.assertEqual(os.listdir(self.state_dir), [])

    def test_restart_then_setup_restores_federation_and_rbac(self):
        self.assert_federation_works()
        self.restart_polaris()
        status, body = self.federated_namespaces()
        if status == 200:
            print("note: the federated catalog survived a restart; Polaris may now persist connection secrets")

        self.run_checked([SETUP])

        self.assert_federation_works()
        self.assert_operator_rbac_intact()
        self.assert_no_journal()

    def test_rejected_tableflow_secret_leaves_catalog_untouched(self):
        before = self.catalog_rbac()

        result = subprocess.run(
            [SETUP], cwd=ROOT, capture_output=True, text=True,
            env={**self.env, "POLARIS_RECREATE_CATALOG": "1", "TABLEFLOW_API_SECRET": "not-the-secret"},
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("left unchanged", result.stderr)
        self.assertEqual(self.catalog_rbac(), before)
        self.assert_no_journal()

    def test_changed_api_key_recreates_catalog(self):
        token = self.token()
        created = self.expect(call("POST", f"{MGMT}/principals", {"principal": {"name": "rotated-api-key"}}, token))
        self.expect(call(
            "PUT", f"{MGMT}/principals/rotated-api-key/principal-roles",
            {"principalRole": {"name": "service_admin"}}, token,
        ))
        credentials = created["credentials"]

        result = self.run_checked(
            [SETUP], TABLEFLOW_API_KEY=credentials["clientId"], TABLEFLOW_API_SECRET=credentials["clientSecret"]
        )

        self.assertIn("client id", result.stdout)
        catalog = self.expect(call("GET", f"{MGMT}/catalogs/{CATALOG}", token=self.token()))
        self.assertEqual(
            catalog["connectionConfigInfo"]["authenticationParameters"]["clientId"], credentials["clientId"]
        )
        self.assert_federation_works()
        self.assert_operator_rbac_intact()
        self.run_checked([SETUP])

    def test_interrupted_recreation_is_resumed_from_the_journal(self):
        journal = pathlib.Path(self.state_dir) / f"catalog-rbac-{REALM}-{CATALOG}.json"
        journal.write_text(json.dumps({"realm": REALM, "catalog": CATALOG, "roles": [{
            "name": "journal_only",
            "properties": {},
            "grants": [{"type": "catalog", "privilege": "VIEW_LIST"}],
            "principalRoles": [OPERATOR_PRINCIPAL_ROLE],
        }]}))

        self.run_checked([SETUP], POLARIS_RECREATE_CATALOG="1")

        rbac = self.catalog_rbac()
        self.assertEqual(rbac["journal_only"]["privileges"], ["VIEW_LIST"])
        self.assertEqual(rbac["journal_only"]["principal_roles"], [OPERATOR_PRINCIPAL_ROLE])
        self.assert_operator_rbac_intact()
        self.assert_federation_works()
        self.assert_no_journal()


if __name__ == "__main__":
    unittest.main()
