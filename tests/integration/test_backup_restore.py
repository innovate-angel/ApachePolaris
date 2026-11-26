"""Backup and restore round trip against the running Compose stack.

Runs with the integration tests once the stack is up: takes a backup with
scripts/backup-postgres.sh, deletes a marker principal role, restores the
backup with scripts/restore-postgres.sh, restarts Polaris, and checks that the
marker is back. Needs the .env values exported; no Azure access (the upload is
skipped when BACKUP_STORAGE_ACCOUNT is unset).
"""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = os.getenv("POLARIS_URL", "http://127.0.0.1:8181")
MGMT = f"{BASE}/api/management/v1"
HEALTH = os.getenv("POLARIS_HEALTH_URL", "http://127.0.0.1:8182/q/health")
REALM = os.getenv("POLARIS_REALM", "ISBUS")
MARKER = "backup_restore_probe"


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
            return response.status
    except urllib.error.HTTPError as error:
        with error:
            return error.code


def token():
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": os.environ["POLARIS_ROOT_CLIENT_ID"],
        "client_secret": os.environ["POLARIS_ROOT_CLIENT_SECRET"],
        "scope": "PRINCIPAL_ROLE:ALL",
    }).encode()
    request = urllib.request.Request(
        f"{BASE}/api/catalog/v1/oauth/tokens", data=data, headers={"Polaris-Realm": REALM}, method="POST"
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode())["access_token"]


class BackupRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.getenv("POLARIS_ROOT_CLIENT_SECRET"):
            raise unittest.SkipTest("Export the .env values (POLARIS_ROOT_CLIENT_SECRET) to run against the stack")
        cls.backup_dir = pathlib.Path(tempfile.mkdtemp(prefix="polaris-backup-test-"))
        cls.addClassCleanup(shutil.rmtree, cls.backup_dir, ignore_errors=True)

    def run_script(self, *args, **env):
        environment = {**os.environ, **env}
        environment.pop("BACKUP_STORAGE_ACCOUNT", None)
        return subprocess.run(["bash", *args], cwd=ROOT, env=environment, capture_output=True, text=True)

    def assert_polaris_healthy(self):
        with urllib.request.urlopen(HEALTH, timeout=10) as response:
            self.assertEqual(json.loads(response.read().decode()).get("status"), "UP")

    def test_backup_prunes_and_restore_brings_data_back(self):
        admin = token()
        self.assertIn(call("POST", f"{MGMT}/principal-roles", {"principalRole": {"name": MARKER}}, admin), (201, 409))

        stale = self.backup_dir / "polaris-20000101T000000Z.dump"
        stale.write_bytes(b"old")
        old = time.time() - 30 * 86400
        os.utime(stale, (old, old))

        backup = self.run_script("scripts/backup-postgres.sh", BACKUP_DIR=str(self.backup_dir), BACKUP_RETENTION_DAYS="14")
        self.assertEqual(backup.returncode, 0, backup.stdout + backup.stderr)
        self.assertIn("BACKUP_STORAGE_ACCOUNT is not set", backup.stderr)
        self.assertFalse(stale.exists(), "a dump older than the retention period was kept")
        dumps = sorted(self.backup_dir.glob("polaris-*.dump"))
        self.assertEqual(len(dumps), 1, dumps)
        self.assertGreater(dumps[0].stat().st_size, 0)

        self.assertEqual(call("DELETE", f"{MGMT}/principal-roles/{MARKER}", token=admin), 204)
        self.assertEqual(call("GET", f"{MGMT}/principal-roles/{MARKER}", token=admin), 404)

        restore = self.run_script("scripts/restore-postgres.sh", str(dumps[0]))
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertIn("RESTORE OK", restore.stdout)

        subprocess.run(["docker", "compose", "up", "-d", "--wait", "polaris"], cwd=ROOT, check=True)
        self.assert_polaris_healthy()
        self.assertEqual(call("GET", f"{MGMT}/principal-roles/{MARKER}", token=token()), 200)

    def test_restore_of_a_missing_file_changes_nothing(self):
        restore = self.run_script("scripts/restore-postgres.sh", str(self.backup_dir / "missing.dump"))
        self.assertNotEqual(restore.returncode, 0)
        self.assertNotIn("RESTORE OK", restore.stdout)
        self.assertIn("not found or empty", restore.stderr)
        self.assert_polaris_healthy()


if __name__ == "__main__":
    unittest.main()
