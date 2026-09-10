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
BOOTSTRAP_UV = PROJECT_ROOT / "deps" / "bin" / "uv" / "uv.exe"
OWNED_PYTHON_ROOT = PROJECT_ROOT / "deps" / "python"
REGISTRATION_PATH = PROJECT_ROOT / "deps" / "registrations" / "pwsh_exec.json"


def owned_python():
    matches = sorted(OWNED_PYTHON_ROOT.glob("cpython-*/python.exe"))
    return matches[-1] if matches else None


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
        locked_names = [package["name"] for package in lock["package"]]

        self.assertTrue(
            all(not item.startswith("uv==") for item in dependencies),
            "uv is the bootstrap launcher, not a Python dependency",
        )
        self.assertNotIn("uv", locked_names)
        self.assertEqual(
            pyproject["tool"]["uv"]["required-version"], f"=={expected}"
        )
        self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(artifact["executable_sha256"], r"^[0-9a-f]{64}$")

    def test_python_interpreter_matches_committed_pin(self):
        expected = PYTHON_PIN_PATH.read_text(encoding="utf-8").strip()
        self.assertEqual(platform.python_version(), expected)

    def test_restore_recipe_has_no_checkout_or_sibling_dependency(self):
        recipe = RESTORE_PATH.read_text(encoding="utf-8")

        self.assertIn("$PSScriptRoot", recipe)
        self.assertIn("deps\\bin\\uv", recipe)
        for forbidden in (
            "D:\\aghado01",
            "science-facility",
            "command-center",
            "PDenv",
        ):
            self.assertNotIn(forbidden, recipe)

    @unittest.skipUnless(BOOTSTRAP_UV.is_file(), "uv is not restored")
    def test_restored_uv_matches_pin(self):
        pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
        artifact = pin["artifacts"]["windows-x64"]

        self.assertEqual(executable_uv_version(BOOTSTRAP_UV), pin["version"])
        self.assertEqual(
            hashlib.sha256(BOOTSTRAP_UV.read_bytes()).hexdigest(),
            artifact["executable_sha256"],
        )

    @unittest.skipUnless(
        REGISTRATION_PATH.is_file(), "machine-local registration is not generated"
    )
    def test_generated_registration_uses_only_project_local_executables(self):
        registration = json.loads(REGISTRATION_PATH.read_text(encoding="utf-8"))
        server = registration["mcpServers"]["pwsh_exec"]
        command = Path(server["command"])

        self.assertEqual(command.name, "python.exe")
        self.assertEqual(command.parent.parent, OWNED_PYTHON_ROOT.resolve())
        self.assertTrue(command.parent.name.startswith("cpython-"))
        self.assertEqual(
            server["args"],
            [
                "-B",
                (PROJECT_ROOT / "server.py").as_posix(),
            ],
        )
        self.assertNotIn("tool_timeout_sec", server)
        env = server["env"]
        self.assertEqual(
            Path(env["MCP_POWERSHELL_EXECUTABLE"]),
            PROJECT_ROOT / "deps" / "bin" / "pwsh" / "pwsh.exe",
        )
        self.assertEqual(
            Path(env["MCP_POWERSHELL_PROFILE"]),
            PROJECT_ROOT / "scripts" / "pwsh" / "profile-pwsh.ps1",
        )

    @unittest.skipUnless(owned_python() is not None, "owned Python interpreter is not restored")
    def test_owned_interpreter_carries_runtime_packages(self):
        python = owned_python()
        output = subprocess.run(
            [python, "-c", "import mcp, win32job; print(mcp.__file__)"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.replace("\\", "/")
        self.assertIn("/site-packages/", output)
        self.assertNotIn("/.venv/", output)
        self.assertIn("/deps/python/", output)


if __name__ == "__main__":
    unittest.main()
