import pathlib
import re
import subprocess
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
            "compose.sh",
            "create-reader-principal.sh",
            "deploy-from-key-vault.sh",
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

    def test_polaris_images_are_release_pinned(self):
        text = (ROOT / "docker-compose.yml").read_text()
        self.assertIn("apache/polaris:1.9.0", text)
        self.assertIn("apache/polaris-admin-tool:1.9.0", text)
        self.assertNotIn("apache/polaris:latest", text)
        self.assertNotIn("apache/polaris-admin-tool:latest", text)

    def test_deploy_entrypoint_runs_full_workflow(self):
        text = (ROOT / "scripts/deploy-from-key-vault.sh").read_text()
        for script in ("bootstrap.sh", "check-tableflow.sh",
                       "setup-tableflow-federation.sh", "verify.sh"):
            self.assertIn(f"./scripts/{script}", text)
        self.assertNotIn("docker compose pull", text)

    def test_key_vault_compose_path_ignores_local_env_file(self):
        text = (ROOT / "scripts/load-key-vault-env.sh").read_text()
        self.assertIn("export COMPOSE_DISABLE_ENV_FILE=1", text)

    def test_sourcing_key_vault_loader_preserves_shell_options(self):
        script = ROOT / "scripts/load-key-vault-env.sh"
        result = subprocess.run(
            [
                "bash",
                "-c",
                'set +e +u +o pipefail; before="$-:$SHELLOPTS"; '
                'az() { if [[ "$1" == login ]]; then return 0; fi; printf "secret\\n"; }; '
                'export VAULT_NAME=test-vault AZURE_TENANT_ID=tenant AZURE_CLIENT_ID=client '
                'AZURE_STORAGE_ACCOUNT=storage AZURE_STORAGE_CONTAINER=container '
                'TABLEFLOW_ORG_ID=org TABLEFLOW_ENV_ID=env; '
                'source "$1"; after="$-:$SHELLOPTS"; '
                '[[ "$before" == "$after" ]]',
                "bash",
                str(script),
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0)

    def test_key_vault_loader_logs_in_with_a_vault_only_managed_identity(self):
        result = subprocess.run(
            [
                "bash",
                "-e",
                "-c",
                """
                az() {
                    if [[ "$1" == login ]]; then
                        case " $* " in
                            *" --allow-no-subscriptions "*) return 0 ;;
                            *) return 1 ;;
                        esac
                    fi
                    printf 'test-secret\\n'
                }
                export VAULT_NAME=test-vault IDENTITY_CLIENT_ID=vm-identity
                export AZURE_TENANT_ID=tenant AZURE_CLIENT_ID=polaris-app
                export AZURE_STORAGE_ACCOUNT=storage AZURE_STORAGE_CONTAINER=container
                export TABLEFLOW_ORG_ID=org TABLEFLOW_ENV_ID=env
                source "$1"
                [[ "$POSTGRES_PASSWORD" == test-secret ]]
                """,
                "bash",
                str(ROOT / "scripts/load-key-vault-env.sh"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

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
