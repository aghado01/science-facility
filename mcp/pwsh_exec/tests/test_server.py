import asyncio
import os
import unittest
from pathlib import Path
from unittest import mock

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

import server


RUNTIME_UV_EXECUTABLE = server.MCP_ROOT / ".venv" / "Scripts" / "uv.exe"


class PowerShellExecutableTests(unittest.TestCase):
    def test_configured_executable_has_precedence_over_bundled_and_path(self):
        environment = {"MCP_POWERSHELL_EXECUTABLE": "C:/shared/pwsh.exe"}

        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch(
                "server._bundled_powershell_executable"
            ) as bundled_executable:
                with mock.patch("server.shutil.which") as which:
                    executable = server._resolve_powershell_executable()

        self.assertEqual(executable, "C:/shared/pwsh.exe")
        bundled_executable.assert_not_called()
        which.assert_not_called()

    def test_bundled_executable_has_precedence_over_path(self):
        bundled_path = "C:/mcp/bin/PowerShell-7.6.4-win-x64/pwsh.exe"

        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch(
                "server._bundled_powershell_executable",
                return_value=bundled_path,
            ):
                with mock.patch("server.shutil.which") as which:
                    executable = server._resolve_powershell_executable()

        self.assertEqual(executable, bundled_path)
        which.assert_not_called()

    def test_blank_configured_executable_falls_back_to_path_when_bundle_missing(self):
        def resolve_from_path(name):
            return "C:/path/pwsh.exe" if name == "pwsh" else None

        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_EXECUTABLE": "   "}, clear=True
        ):
            with mock.patch(
                "server._bundled_powershell_executable", return_value=None
            ):
                with mock.patch(
                    "server.shutil.which",
                    side_effect=resolve_from_path,
                ):
                    executable = server._resolve_powershell_executable()

        self.assertEqual(executable, "C:/path/pwsh.exe")


class PowerShellProfileTests(unittest.TestCase):
    def test_profile_is_not_loaded_when_variable_is_absent(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            code = server._build_powershell_code("Get-Date")

        self.assertNotIn("MCP_POWERSHELL_PROFILE", code)
        self.assertTrue(code.endswith("Get-Date"))

    def test_blank_profile_is_treated_as_unset(self):
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_PROFILE": "   "}, clear=True
        ):
            code = server._build_powershell_code("Get-Date")

        self.assertNotIn("MCP_POWERSHELL_PROFILE", code)

    def test_profile_is_resolved_literally_and_dot_sourced(self):
        profile_path = "C:/profiles/client's profile.ps1"
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_PROFILE": profile_path}, clear=True
        ):
            code = server._build_powershell_code("Get-ProfileValue")

        self.assertIn(
            "Resolve-Path -LiteralPath $env:MCP_POWERSHELL_PROFILE", code
        )
        self.assertIn("$null = . $__mcpPowerShellProfile", code)
        self.assertNotIn(profile_path, code)
        self.assertTrue(code.endswith("Get-ProfileValue"))

    def test_configured_profile_is_included_in_spawned_command(self):
        process = mock.Mock()
        process.returncode = 0
        process.communicate.return_value = ("profile-loaded\n", "")
        environment = {
            "MCP_POWERSHELL_EXECUTABLE": "C:/runtime/pwsh.exe",
            "MCP_POWERSHELL_PROFILE": "C:/profiles/client-a.ps1",
        }

        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch("server.subprocess.Popen", return_value=process) as popen:
                output = server._run_powershell("Get-ProfileValue")

        command = popen.call_args.args[0]
        self.assertEqual(command[:3], ["C:/runtime/pwsh.exe", "-NoProfile", "-Command"])
        self.assertIn("$env:MCP_POWERSHELL_PROFILE", command[3])
        self.assertEqual(output, "profile-loaded\n")


class PowerShellProfileIntegrationTests(unittest.TestCase):
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

        with mock.patch.dict(os.environ, environment, clear=False):
            output = server._run_powershell("Get-McpPowerShellProfileTestValue")

        self.assertEqual(output.strip(), "profile-loaded")

    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(),
        "the bundled PowerShell runtime is not installed",
    )
    def test_bundled_powershell_version(self):
        with mock.patch.dict(
            os.environ, {"MCP_POWERSHELL_EXECUTABLE": ""}, clear=False
        ):
            output = server._run_powershell(
                "$PSVersionTable.PSVersion.ToString()"
            )

        self.assertEqual(output.strip(), "7.6.4")


class PowerShellMcpIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(
        server.DEFAULT_POWERSHELL_EXECUTABLE.is_file()
        and RUNTIME_UV_EXECUTABLE.is_file(),
        "the bundled PowerShell and project uv runtimes are not installed",
    )
    def test_stdio_server_exposes_and_runs_powershell_tool(self):
        initialization, tools, result = asyncio.run(
            self._call_bundled_powershell_over_stdio()
        )

        self.assertEqual(initialization.serverInfo.name, "pwsh_exec")
        self.assertEqual([tool.name for tool in tools.tools], ["run_powershell"])
        self.assertFalse(result.isError)
        self.assertEqual(result.content[0].text.strip(), "7.6.4")

    async def _call_bundled_powershell_over_stdio(self):
        environment = os.environ.copy()
        environment.pop(server.POWERSHELL_EXECUTABLE_ENV_VAR, None)
        environment.pop(server.POWERSHELL_PROFILE_ENV_VAR, None)
        parameters = StdioServerParameters(
            command=str(RUNTIME_UV_EXECUTABLE),
            args=[
                "run",
                "--no-cache",
                "--locked",
                "--no-sync",
                "python",
                "-B",
                str(server.MCP_ROOT / "server.py"),
            ],
            cwd=server.MCP_ROOT,
            env=environment,
        )

        async with stdio_client(parameters) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                initialization = await session.initialize()
                tools = await session.list_tools()
                result = await session.call_tool(
                    "run_powershell",
                    {"code": "$PSVersionTable.PSVersion.ToString()"},
                )

        return initialization, tools, result


if __name__ == "__main__":
    unittest.main()
