import hashlib
import json
import platform
import subprocess
import tomllib
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = PROJECT_ROOT / "brewery" / "uv" / "pin.json"
RESTORE_PATH = PROJECT_ROOT / "brewery" / "uv" / "restore-uv.ps1"
PYTHON_PIN_PATH = PROJECT_ROOT / ".python-version"
PYPROJECT_PATH = PROJECT_ROOT / "pyproject.toml"
LOCK_PATH = PROJECT_ROOT / "uv.lock"
BOOTSTRAP_UV = PROJECT_ROOT / "packages" / "uv" / "uv.exe"
RUNTIME_UV = PROJECT_ROOT / ".venv" / "Scripts" / "uv.exe"
REGISTRATION_PATH = PROJECT_ROOT / "packages" / "registrations" / "pwsh_exec.json"


def read_toml(path: Path):
    return tomllib.loads(path.read_text(encoding="utf-8"))


def executable_uv_version(path: Path):
    output = subprocess.run(
        [path, "--version"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout
    return output.split()[1]


class DependencyContractTests(unittest.TestCase):
    def test_uv_versions_agree_across_all_committed_layers(self):
        pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
        pyproject = read_toml(PYPROJECT_PATH)
        lock = read_toml(LOCK_PATH)

        expected = pin["version"]
        artifact = pin["artifacts"]["windows-x64"]
        dependencies = pyproject["project"]["dependencies"]
        locked_uv = next(
            package for package in lock["package"] if package["name"] == "uv"
        )

        self.assertIn(f"uv=={expected}", dependencies)
        self.assertEqual(
            pyproject["tool"]["uv"]["required-version"], f"=={expected}"
        )
        self.assertEqual(locked_uv["version"], expected)
        self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(artifact["executable_sha256"], r"^[0-9a-f]{64}$")

    def test_python_interpreter_matches_committed_pin(self):
        expected = PYTHON_PIN_PATH.read_text(encoding="utf-8").strip()
        self.assertEqual(platform.python_version(), expected)

    def test_restore_recipe_has_no_checkout_or_sibling_dependency(self):
        recipe = RESTORE_PATH.read_text(encoding="utf-8")

        self.assertIn("$PSScriptRoot", recipe)
        self.assertIn("packages\\uv", recipe)
        for forbidden in (
            "D:\\aghado01",
            "science-facility",
            "command-center",
            "PDenv",
        ):
            self.assertNotIn(forbidden, recipe)

    @unittest.skipUnless(BOOTSTRAP_UV.is_file(), "bootstrap uv is not restored")
    def test_restored_bootstrap_matches_pin(self):
        pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
        artifact = pin["artifacts"]["windows-x64"]

        self.assertEqual(executable_uv_version(BOOTSTRAP_UV), pin["version"])
        self.assertEqual(
            hashlib.sha256(BOOTSTRAP_UV.read_bytes()).hexdigest(),
            artifact["executable_sha256"],
        )

    @unittest.skipUnless(RUNTIME_UV.is_file(), "runtime uv is not restored")
    def test_runtime_uv_matches_pin(self):
        expected = json.loads(PIN_PATH.read_text(encoding="utf-8"))["version"]
        self.assertEqual(executable_uv_version(RUNTIME_UV), expected)

    @unittest.skipUnless(
        REGISTRATION_PATH.is_file(), "machine-local registration is not generated"
    )
    def test_generated_registration_uses_only_project_local_executables(self):
        registration = json.loads(REGISTRATION_PATH.read_text(encoding="utf-8"))
        server = registration["mcpServers"]["pwsh_exec"]

        self.assertEqual(Path(server["command"]), RUNTIME_UV)
        self.assertEqual(Path(server["args"][-1]), PROJECT_ROOT / "server.py")
        self.assertEqual(
            server["args"][:-1],
            [
                "run",
                "--project",
                PROJECT_ROOT.as_posix(),
                "--no-cache",
                "--locked",
                "--no-sync",
                "python",
                "-B",
            ],
        )


if __name__ == "__main__":
    unittest.main()
