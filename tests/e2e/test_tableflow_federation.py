import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class TableflowFederationE2ETests(unittest.TestCase):
    def test_external_catalog(self):
        result = subprocess.run(
            [str(ROOT / "scripts" / "setup-tableflow-federation.sh")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_verify_end_to_end(self):
        result = subprocess.run(
            [str(ROOT / "scripts" / "verify.sh")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
