"""Polaris must reach PostgreSQL through its own non-superuser role.

Runs with the integration tests against the running Compose stack (needs the
.env values exported).
"""

import os
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP_USER = os.getenv("POLARIS_DB_USER", "polaris_app")


def psql(sql):
    result = subprocess.run(
        ["docker", "compose", "exec", "-T", "postgres",
         "sh", "-c", 'psql -tA -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d POLARIS'],
        cwd=ROOT, input=sql, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


class DatabaseRoleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.getenv("POLARIS_DB_PASSWORD"):
            raise unittest.SkipTest("Export the .env values (POLARIS_DB_PASSWORD) to run against the stack")

    def test_app_role_has_no_admin_rights(self):
        self.assertEqual(
            psql(f"SELECT rolsuper, rolcreaterole, rolcreatedb, rolbypassrls FROM pg_roles WHERE rolname = '{APP_USER}';"),
            "f|f|f|f",
        )

    def test_polaris_connects_as_app_role(self):
        self.assertGreater(int(psql(f"SELECT count(*) FROM pg_stat_activity WHERE usename = '{APP_USER}';")), 0)

    def test_polaris_tables_are_owned_by_app_role(self):
        owners = psql("SELECT DISTINCT tableowner FROM pg_tables WHERE schemaname = 'polaris_schema';").split()
        self.assertEqual(owners, [APP_USER])

    def test_role_script_migrates_superuser_owned_objects(self):
        psql("CREATE TABLE polaris_schema.legacy_probe (id int); CREATE SEQUENCE polaris_schema.legacy_probe_seq;")
        self.addCleanup(psql, "DROP TABLE IF EXISTS polaris_schema.legacy_probe; "
                              "DROP SEQUENCE IF EXISTS polaris_schema.legacy_probe_seq;")
        result = subprocess.run(
            ["docker", "compose", "--profile", "bootstrap", "run", "--rm", "polaris-db-role"],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            psql("SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid IN "
                 "('polaris_schema.legacy_probe'::regclass, 'polaris_schema.legacy_probe_seq'::regclass);").split(),
            [APP_USER, APP_USER],
        )


if __name__ == "__main__":
    unittest.main()
