import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class RepositoryStructureTests(unittest.TestCase):
    def test_compose_file_exists(self):
        self.assertTrue((ROOT / "docker-compose.yml").is_file())

    def test_env_template_has_required_values(self):
        text = (ROOT / ".env.example").read_text()
        required = (
            "POSTGRES_USER",
            "POSTGRES_PASSWORD",
            "POLARIS_ROOT_CLIENT_ID",
            "POLARIS_ROOT_CLIENT_SECRET",
            "POLARIS_TOKEN_BROKER_SECRET",
            "POLARIS_REALM",
        )
        for name in required:
            self.assertRegex(text, rf"(?m)^{re.escape(name)}=")

    def test_required_scripts_exist_and_are_executable(self):
        for name in (
            "bootstrap.sh",
            "check-tableflow.sh",
            "setup-tableflow-federation.sh",
            "verify.sh",
        ):
            path = ROOT / "scripts" / name
            self.assertTrue(path.is_file())
            self.assertTrue(path.stat().st_mode & 0o111)

    def test_compose_has_required_services_and_ports(self):
        text = (ROOT / "docker-compose.yml").read_text()
        self.assertIn("postgres:", text)
        self.assertIn("polaris-bootstrap:", text)
        self.assertIn("polaris:", text)
        self.assertIn("8181:8181", text)
        self.assertIn("127.0.0.1:8182:8182", text)

    def test_compose_uses_jdbc_pool_settings(self):
        text = (ROOT / "docker-compose.yml").read_text()
        self.assertIn("QUARKUS_DATASOURCE_DB_KIND: postgresql", text)
        self.assertIn('QUARKUS_DATASOURCE_JDBC_MIN_SIZE: "2"', text)
        self.assertIn('QUARKUS_DATASOURCE_JDBC_MAX_SIZE: "20"', text)

    def test_no_merge_conflict_markers(self):
        for path in ROOT.rglob("*"):
            if path.is_file() and ".git" not in path.parts:
                if path == pathlib.Path(__file__).resolve():
                    continue
                try:
                    text = path.read_text()
                except (UnicodeDecodeError, OSError):
                    continue
                self.assertNotIn("<<<<<<<", text, str(path))
                self.assertNotIn(">>>>>>>", text, str(path))


if __name__ == "__main__":
    unittest.main()
