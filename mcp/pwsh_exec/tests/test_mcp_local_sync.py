import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SYNC_PATH = PROJECT_ROOT / "brewery" / "uv" / "sync-mcp-local.py"


def load_sync():
    spec = importlib.util.spec_from_file_location("sync_mcp_local", SYNC_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SYNC = load_sync()

GENERIC_REG = {
    "command": "D:/src/pwsh_exec/deps/python/cpython-3.13.6-windows-x86_64-none/python.exe",
    "args": ["-B", "D:/src/pwsh_exec/server.py"],
    "env": {
        "MCP_POWERSHELL_EXECUTABLE": "D:/src/pwsh_exec/deps/bin/pwsh/pwsh.exe",
        "MCP_POWERSHELL_PROFILE": "D:/src/pwsh_exec/scripts/pwsh/profile-pwsh.ps1",
    },
}


class McpLocalSyncTests(unittest.TestCase):
    def test_relative_registration_for_checkout_root(self):
        block = SYNC.registration_for_target(
            GENERIC_REG, Path("D:/src")
        )
        self.assertEqual(
            block["command"],
            "./pwsh_exec/deps/python/cpython-3.13.6-windows-x86_64-none/python.exe",
        )
        self.assertEqual(block["args"], ["-B", "./pwsh_exec/server.py"])
        self.assertEqual(
            block["env"]["MCP_POWERSHELL_PROFILE"],
            "./pwsh_exec/scripts/pwsh/profile-pwsh.ps1",
        )

    def test_json_preserves_extra_keys_and_surrounding_file(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "mcp.json"
            path.write_text(
                '{\n  "keep": true,\n  "mcpServers": {\n'
                '    "other": {"command": "node"},\n'
                '    "pwsh_exec": {\n'
                '      "type": "stdio",\n'
                '      "command": "old.exe",\n'
                '      "args": ["run", "old.py"],\n'
                '      "env": {\n'
                '        "MCP_POWERSHELL_PROFILE": '
                '"D:/src/pwsh_exec/scripts/pwsh/profile-pwsh.ps1",\n'
                '        "EXTRA": "1"\n'
                "      }\n"
                "    }\n"
                "  }\n}\n",
                encoding="utf-8",
            )
            block = SYNC.registration_for_target(GENERIC_REG, None)
            self.assertTrue(SYNC.apply_json(path, block))
            data = json.loads(path.read_text(encoding="utf-8"))
            server = data["mcpServers"]["pwsh_exec"]
            self.assertEqual(server["type"], "stdio")
            self.assertEqual(server["command"], GENERIC_REG["command"])
            self.assertEqual(server["args"], GENERIC_REG["args"])
            self.assertEqual(server["env"]["EXTRA"], "1")
            self.assertEqual(
                server["env"]["MCP_POWERSHELL_PROFILE"],
                GENERIC_REG["env"]["MCP_POWERSHELL_PROFILE"],
            )
            self.assertTrue(data["keep"])
            self.assertEqual(data["mcpServers"]["other"]["command"], "node")

    def test_toml_rewrites_only_pwsh_exec_and_keeps_timeouts(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "config.toml"
            path.write_text(
                '[mcp_servers.mdnav]\n'
                'command = "node"\n'
                "args = [\n  \"./mcp/mdnav/src/index.ts\"\n]\n"
                "startup_timeout_sec = 30\n"
                "\n"
                "[mcp_servers.pwsh_exec]\n"
                'command = "old.exe"\n'
                "args = [\n"
                '  "run",\n'
                '  "--project",\n'
                '  "D:/src/pwsh_exec",\n'
                '  "old.py",\n'
                "]\n"
                "startup_timeout_sec = 30\n"
                "tool_timeout_sec = 8400\n"
                "tool_timeouts = { run_powershell = 8400 }\n"
                "\n"
                "[mcp_servers.pwsh_exec.env]\n"
                'MCP_POWERSHELL_EXECUTABLE = "old-pwsh"\n'
                'MCP_POWERSHELL_PROFILE = '
                '"D:/src/pwsh_exec/scripts/pwsh/profile-pwsh.ps1"\n',
                encoding="utf-8",
            )
            block = SYNC.registration_for_target(GENERIC_REG, Path("D:/src"))
            self.assertTrue(SYNC.apply_toml(path, block))
            text = path.read_text(encoding="utf-8")
            self.assertIn('command = "node"', text)
            self.assertIn("./mcp/mdnav/src/index.ts", text)
            self.assertIn("tool_timeout_sec = 8400", text)
            self.assertIn("tool_timeouts = { run_powershell = 8400 }", text)
            self.assertIn(
                "tool_timeouts = { run_powershell = 8400 }\n\n[mcp_servers.pwsh_exec.env]",
                text,
            )
            self.assertIn("startup_timeout_sec = 30", text)
            self.assertIn(
                'command = "./pwsh_exec/deps/python/cpython-3.13.6-windows-x86_64-none/python.exe"',
                text,
            )
            self.assertIn('"-B"', text)
            self.assertNotIn('"run"', text)
            self.assertNotIn("old.exe", text)
            self.assertIn(
                'MCP_POWERSHELL_PROFILE = "./pwsh_exec/scripts/pwsh/profile-pwsh.ps1"',
                text,
            )

    def test_json_refuses_latexai_profile(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "mcp.json"
            path.write_text(
                '{\n  "mcpServers": {\n    "pwsh_exec": {\n'
                '      "command": "old.exe",\n'
                '      "args": ["-B", "old.py"],\n'
                '      "env": {\n'
                '        "MCP_POWERSHELL_PROFILE": '
                '"D:/work/LaTeXAI/scripts/profile.ps1",\n'
                '        "LATEXAI_ROOT": "D:/work/LaTeXAI"\n'
                "      }\n    }\n  }\n}\n",
                encoding="utf-8",
            )
            original = path.read_text(encoding="utf-8")
            self.assertFalse(
                SYNC.apply_json(path, SYNC.registration_for_target(GENERIC_REG, None))
            )
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_toml_refuses_latexai_path(self):
        with tempfile.TemporaryDirectory() as raw:
            latexai = Path(raw) / "LaTeXAI"
            latexai.mkdir()
            path = latexai / "config.toml"
            path.write_text(
                "[mcp_servers.pwsh_exec]\n"
                'command = "old.exe"\n'
                "args = [\"-B\"]\n"
                "\n"
                "[mcp_servers.pwsh_exec.env]\n"
                'MCP_POWERSHELL_PROFILE = '
                '"D:/work/LaTeXAI/scripts/profile.ps1"\n',
                encoding="utf-8",
            )
            original = path.read_text(encoding="utf-8")
            self.assertFalse(
                SYNC.apply_toml(path, SYNC.registration_for_target(GENERIC_REG, None))
            )
            self.assertEqual(path.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
