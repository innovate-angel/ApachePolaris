"""Behaviour tests for scripts/verify.sh against a stub Polaris HTTP server."""

import http.server
import json
import os
import pathlib
import subprocess
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG_API = "/api/catalog/v1/tableflow"
LOCATION = "abfss://tableflow@acct.dfs.core.windows.net/lkc-b/orders/metadata/v1.metadata.json"
SAS_KEY = "adls.sas-token.acct.dfs.core.windows.net"


class StubPolaris(http.server.BaseHTTPRequestHandler):
    routes = {}

    def respond(self):
        status, body = self.routes.get(self.path.split("?")[0], (404, {"error": {"message": "not found"}}))
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.respond()

    def log_message(self, *args):
        pass


def routes(namespaces=(["lkc-b"],), tables=None, table=None, **overrides):
    """Routes for a catalog whose namespace lkc-b holds the table `orders`."""
    result = {
        "/api/catalog/v1/oauth/tokens": (200, {"access_token": "stub-token"}),
        "/api/catalog/v1/config": (200, {"defaults": {}, "overrides": {}}),
        f"{CATALOG_API}/namespaces": (200, {"namespaces": list(namespaces)}),
        f"{CATALOG_API}/namespaces/lkc-b/tables": (
            200, {"identifiers": [{"namespace": ["lkc-b"], "name": "orders"}]} if tables is None else tables,
        ),
        f"{CATALOG_API}/namespaces/lkc-b/tables/orders": (
            200, {"metadata-location": LOCATION, "config": {SAS_KEY: "sv=stub"}} if table is None else table,
        ),
    }
    result.update(overrides)
    return result


class VerifyScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubPolaris)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.server.server_close)
        cls.addClassCleanup(cls.server.shutdown)

    def verify(self, stub_routes, **env):
        StubPolaris.routes = stub_routes
        return subprocess.run(
            [str(ROOT / "scripts" / "verify.sh")],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "POLARIS_URL": f"http://127.0.0.1:{self.server.server_port}",
                "POLARIS_ROOT_CLIENT_ID": "admin",
                "POLARIS_ROOT_CLIENT_SECRET": "secret",
                "AZURE_STORAGE_ACCOUNT": "acct",
                "AZURE_STORAGE_CONTAINER": "tableflow",
                **env,
            },
        )

    def test_passes_when_sas_credentials_are_vended(self):
        result = self.verify(routes())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All checks passed.", result.stdout)
        self.assertIn(SAS_KEY, result.stdout)
        self.assertNotIn("sv=stub", result.stdout)

    def test_passes_when_sas_credentials_are_in_storage_credentials(self):
        table = {
            "metadata-location": LOCATION,
            "config": {},
            "storage-credentials": [{"prefix": "abfss://tableflow@acct.dfs.core.windows.net/", "config": {SAS_KEY: "sv=stub"}}],
        }
        result = self.verify(routes(table=table))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fails_when_no_sas_credentials_are_vended(self):
        result = self.verify(routes(table={"metadata-location": LOCATION, "config": {"other": "x"}}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("vended no ADLS SAS credentials", result.stderr)
        self.assertNotIn("All checks passed.", result.stdout)

    def test_fails_when_table_is_outside_the_expected_container(self):
        elsewhere = LOCATION.replace("tableflow@acct", "other@acct")
        result = self.verify(routes(table={"metadata-location": elsewhere, "config": {SAS_KEY: "sv=stub"}}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("not in container 'tableflow'", result.stderr)

    def test_accepts_blob_endpoint_location(self):
        blob = "https://acct.blob.core.windows.net/tableflow/lkc-b/orders/metadata/v1.metadata.json"
        result = self.verify(routes(table={"metadata-location": blob, "config": {SAS_KEY: "sv=stub"}}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_inconclusive_when_catalog_has_no_namespaces(self):
        result = self.verify(routes(namespaces=()))
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("INCONCLUSIVE", result.stderr)

    def test_inconclusive_when_no_namespace_has_a_table(self):
        result = self.verify(routes(tables={"identifiers": []}))
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertNotIn("All checks passed.", result.stdout)

    def test_looks_past_an_empty_first_namespace(self):
        stub = routes(
            namespaces=(["lkc-a"], ["lkc-b"]),
            **{f"{CATALOG_API}/namespaces/lkc-a/tables": (200, {"identifiers": []})},
        )
        result = self.verify(stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("loadTable lkc-b.orders", result.stdout)

    def test_nested_namespace_is_joined_with_the_unit_separator(self):
        stub = routes(
            namespaces=(["env", "lkc-c"],),
            **{
                f"{CATALOG_API}/namespaces/env%1Flkc-c/tables": (
                    200, {"identifiers": [{"namespace": ["env", "lkc-c"], "name": "orders"}]},
                ),
                f"{CATALOG_API}/namespaces/env%1Flkc-c/tables/orders": (
                    200, {"metadata-location": LOCATION, "config": {SAS_KEY: "sv=stub"}},
                ),
            },
        )
        result = self.verify(stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fails_with_the_response_when_the_federated_call_errors(self):
        error = {"error": {"message": None, "type": "NullPointerException", "code": 500}}
        result = self.verify(routes(**{f"{CATALOG_API}/namespaces": (500, error)}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("HTTP 500", result.stderr)
        self.assertIn("NullPointerException", result.stderr)
        self.assertIn("deploy-from-key-vault.sh", result.stderr)

    def test_fails_when_load_table_is_rejected(self):
        denied = {"error": {"message": "Forbidden", "code": 403}}
        result = self.verify(routes(**{f"{CATALOG_API}/namespaces/lkc-b/tables/orders": (403, denied)}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("HTTP 403", result.stderr)

    def test_fails_when_the_token_request_is_rejected(self):
        result = self.verify(routes(**{"/api/catalog/v1/oauth/tokens": (401, {"error": "invalid_client"})}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("token request", result.stderr)

    def test_location_is_not_checked_without_storage_settings(self):
        elsewhere = LOCATION.replace("tableflow@acct", "other@acct")
        result = self.verify(
            routes(table={"metadata-location": elsewhere, "config": {SAS_KEY: "sv=stub"}}),
            AZURE_STORAGE_ACCOUNT="", AZURE_STORAGE_CONTAINER="",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("table location not checked", result.stdout)


if __name__ == "__main__":
    unittest.main()
