import asyncio
import json
import os
import unittest
from pathlib import Path
from unittest import mock

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

import server


RUNTIME_UV_EXECUTABLE = server.MCP_ROOT / "deps" / "bin" / "uv" / "uv.exe"


class PowerShellExecutableTests(unittest.TestCase):
    def test_configured_executable_overrides_default(self):
        environment = {"MCP_POWERSHELL_EXECUTABLE": "C:/custom/pwsh.exe"}

        with mock.patch.dict(os.environ, environment, clear=True):
            executable = server._resolve_powershell_executable()

        self.assertEqual(executable, "C:/custom/pwsh.exe")

    def test_default_executable_is_bundled_pwsh(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            executable = server._resolve_powershell_executable()

        self.assertEqual(executable, str(server.DEFAULT_POWERSHELL_EXECUTABLE))

    def test_blank_configured_executable_uses_default(self):
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_EXECUTABLE": "   "}, clear=True
        ):
            executable = server._resolve_powershell_executable()

        self.assertEqual(executable, str(server.DEFAULT_POWERSHELL_EXECUTABLE))


class PowerShellProfileTests(unittest.TestCase):
    def test_default_profile_resolves_to_bundled_profile_when_variable_is_absent(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            profile = server._resolve_powershell_profile()

        expected = str(server.DEFAULT_POWERSHELL_PROFILE) if server.DEFAULT_POWERSHELL_PROFILE.is_file() else None
        self.assertEqual(profile, expected)

    def test_blank_profile_resolves_to_none(self):
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_PROFILE": "   "}, clear=True
        ):
            profile = server._resolve_powershell_profile()

        self.assertIsNone(profile)

    def test_configured_profile_is_resolved(self):
        profile_path = "C:/profiles/client's profile.ps1"
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_PROFILE": profile_path}, clear=True
        ):
            profile = server._resolve_powershell_profile()

        self.assertEqual(profile, profile_path)

    def test_profile_is_embedded_in_command_text(self):
        text = server._build_powershell_code("Get-ProfileValue")
        self.assertIn("$env:MCP_POWERSHELL_PROFILE", text)
        self.assertIn("Get-ProfileValue", text)

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_default_profile_is_loaded_by_bundled_powershell(self):
        environment = {
            "MCP_POWERSHELL_EXECUTABLE": "",
        }

        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell("$env:MCP_POWERSHELL_PROFILE", timeout_seconds=30)

        self.assertTrue(result["success"])
        self.assertIn("profile-pwsh.ps1", result["stdout"])

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_configured_profile_is_loaded_by_bundled_powershell(self):
        profile_path = Path(__file__).parent / "fixtures" / "profile.ps1"
        environment = {
            "MCP_POWERSHELL_EXECUTABLE": "",
            "MCP_POWERSHELL_PROFILE": str(profile_path),
        }

        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell("Get-McpPowerShellProfileTestValue", timeout_seconds=30)

        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"].strip(), "profile-loaded")

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_bundled_powershell_version(self):
        with mock.patch.dict(
            os.environ,
            {"MCP_POWERSHELL_EXECUTABLE": "", "MCP_POWERSHELL_PROFILE": " "},
            clear=True,
        ):
            result = server._run_powershell(
                "$PSVersionTable.PSVersion.ToString()", timeout_seconds=30
            )

        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"].strip(), "7.6.4")
        self.assertGreaterEqual(
            tuple(int(p) for p in result["powershell"]["version"].split(".")[:2]),
            (7, 5),
        )


class PowerShellResultContractTests(unittest.TestCase):
    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_successful_stderr_is_retained(self):
        result = server._run_powershell(
            "[Console]::Error.WriteLine('warn'); 'ok'", timeout_seconds=30
        )
        self.assertTrue(result["success"])
        self.assertEqual(result["native_exit_code"], 0)
        self.assertIn("ok", result["stdout"])
        self.assertIn("warn", result["stderr"])

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_failure_preserves_stdout_and_nonzero_exit(self):
        result = server._run_powershell(
            "Write-Output 'report'; exit 7", timeout_seconds=30
        )
        self.assertFalse(result["success"])
        self.assertEqual(result["native_exit_code"], 7)
        self.assertEqual(result["outcome"], "exited")
        self.assertIn("report", result["stdout"])

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_timeout_kills_descendant_and_keeps_partial_stdout(self):
        result = server._run_powershell(
            "Write-Output 'before'; Start-Sleep -Seconds 30; Write-Output 'after'",
            timeout_seconds=2,
        )
        self.assertEqual(result["outcome"], "timed-out")
        self.assertFalse(result["success"])
        self.assertIn("before", result["stdout"])
        self.assertNotIn("after", result["stdout"])
        self.assertEqual(result["cleanup"], "complete")

    def test_missing_cwd_does_not_run_code(self):
        result = server._run_powershell("Write-Output 'sentinel'", cwd="D:/no-such-cwd-latexai")
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertIn("cwd is not a directory", result["stderr"])
        self.assertNotIn("sentinel", result["stdout"])

    def test_zero_timeout_without_unbounded_is_rejected(self):
        with self.assertRaises(ValueError):
            server._run_powershell("Write-Output 1", timeout_seconds=0)


class PowerShellMcpIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file()
        and RUNTIME_UV_EXECUTABLE.is_file(),
        "the bundled PowerShell and project uv runtimes are not installed",
    )
    def test_stdio_server_runs_from_outside_project_directory(self):
        initialization, tools, result = asyncio.run(
            self._call_bundled_powershell_over_stdio()
        )

        self.assertEqual(initialization.serverInfo.name, "pwsh_exec")
        self.assertEqual([tool.name for tool in tools.tools], ["run_powershell"])
        self.assertFalse(result.isError)
        payload = json.loads(result.content[0].text)
        self.assertEqual(payload["stdout"].strip(), "7.6.4")
        self.assertTrue(payload["success"])

    async def _call_bundled_powershell_over_stdio(self):
        environment = os.environ.copy()
        environment.pop(server.POWERSHELL_EXECUTABLE_ENV_VAR, None)
        environment.pop(server.POWERSHELL_PROFILE_ENV_VAR, None)
        parameters = StdioServerParameters(
            command=str(RUNTIME_UV_EXECUTABLE),
            args=[
                "run",
                "--project",
                str(server.MCP_ROOT),
                "--no-cache",
                "--locked",
                str(server.MCP_ROOT / "server.py"),
            ],
            cwd=server.MCP_ROOT.parent,
            env=environment,
        )

        async with stdio_client(parameters) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                initialization = await session.initialize()
                tools = await session.list_tools()
                result = await session.call_tool(
                    "run_powershell",
                    {
                        "code": "$PSVersionTable.PSVersion.ToString()",
                        "timeout_seconds": 30,
                    },
                )

        return initialization, tools, result


if __name__ == "__main__":
    unittest.main()
