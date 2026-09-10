import asyncio
import json
import os
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest import mock

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.types import (
    CallToolResult,
    CancelledNotification,
    CancelledNotificationParams,
    ClientNotification,
)

import invocation
import server
from windows_job import pid_is_running


FIXTURES = Path(__file__).parent / "fixtures"


def owned_python():
    matches = sorted((server.MCP_ROOT / "deps" / "python").glob("cpython-*/python.exe"))
    return matches[-1] if matches else None


def _have_runtime() -> bool:
    return server.DEFAULT_POWERSHELL_EXECUTABLE.is_file()


def _have_owned_python() -> bool:
    python = owned_python()
    return python is not None and python.is_file()


def _latexai_roots():
    root = os.environ.get("LATEXAI_ROOT")
    perl = os.environ.get("PERL_ROOT")
    cdxsci = os.environ.get("CDXSCI_ROOT")
    if not (root and perl and cdxsci):
        return None
    checkout = Path(root)
    if not (
        checkout.is_dir()
        and (checkout / "scripts" / "profile.ps1").is_file()
        and (checkout / "scripts" / "test-run.ps1").is_file()
        and (checkout / "scripts" / "tests" / "tap" / "fail.t").is_file()
        and Path(perl).is_dir()
        and Path(cdxsci).is_dir()
    ):
        return None
    return checkout


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

        expected = (
            str(server.DEFAULT_POWERSHELL_PROFILE)
            if server.DEFAULT_POWERSHELL_PROFILE.is_file()
            else None
        )
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

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_default_profile_is_loaded_by_bundled_powershell(self):
        environment = {"MCP_POWERSHELL_EXECUTABLE": ""}

        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell(
                "$env:MCP_POWERSHELL_PROFILE", timeout_seconds=30
            )

        self.assertTrue(result["success"])
        self.assertIn("profile-pwsh.ps1", result["stdout"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_default_profile_does_not_load_latexai_aliases_or_console_furniture(self):
        environment = {"MCP_POWERSHELL_EXECUTABLE": ""}
        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell(
                "@(Get-Command lxml, Set-ConsolePrompt -ErrorAction SilentlyContinue).Name -join ','",
                timeout_seconds=30,
            )
        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"].strip(), "")

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_configured_profile_is_loaded_by_bundled_powershell(self):
        profile_path = FIXTURES / "profile.ps1"
        environment = {
            "MCP_POWERSHELL_EXECUTABLE": "",
            "MCP_POWERSHELL_PROFILE": str(profile_path),
        }

        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell(
                "Get-McpPowerShellProfileTestValue", timeout_seconds=30
            )

        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"].strip(), "profile-loaded")

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_blank_profile_skips_default_and_runs_user_code(self):
        environment = {
            "MCP_POWERSHELL_EXECUTABLE": "",
            "MCP_POWERSHELL_PROFILE": " ",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            result = server._run_powershell(
                "Write-Output 'no-profile'", timeout_seconds=30
            )
        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"].strip(), "no-profile")
        self.assertIsNone(result["powershell"]["profile"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
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
        self.assertEqual(result["powershell"]["version"], "7.6.4")
        self.assertIn(".NET 10", result["powershell"]["dotnet"])


class PowerShellResultContractTests(unittest.TestCase):
    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_successful_stderr_is_retained(self):
        result = server._run_powershell(
            "[Console]::Error.WriteLine('warn'); 'ok'", timeout_seconds=30
        )
        self.assertEqual(result["schema"], invocation.RESULT_SCHEMA)
        self.assertTrue(result["success"])
        self.assertEqual(result["native_exit_code"], 0)
        self.assertEqual(result["outcome"], "exited")
        self.assertIn("ok", result["stdout"])
        self.assertIn("warn", result["stderr"])
        self.assertEqual(result["cleanup"]["status"], "complete")
        self.assertEqual(result["timeout_seconds_requested"], 30)
        self.assertEqual(result["timeout_seconds_effective"], 30)

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_failure_preserves_stdout_and_nonzero_exit(self):
        result = server._run_powershell(
            "Write-Output 'report'; exit 7", timeout_seconds=30
        )
        self.assertFalse(result["success"])
        self.assertEqual(result["native_exit_code"], 7)
        self.assertEqual(result["outcome"], "exited")
        self.assertIn("report", result["stdout"])
        self.assertEqual(result["timeout_seconds_effective"], 30)
        self.assertNotEqual(result["native_exit_code"], 0)

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_zero_exit_with_stderr_is_success(self):
        result = server._run_powershell(
            "[Console]::Error.WriteLine('not-a-failure'); exit 0",
            timeout_seconds=30,
        )
        self.assertTrue(result["success"])
        self.assertEqual(result["native_exit_code"], 0)
        self.assertIn("not-a-failure", result["stderr"])

    def test_missing_cwd_does_not_run_code(self):
        result = server._run_powershell(
            "Write-Output 'sentinel'", cwd="D:/no-such-cwd-pwsh-exec"
        )
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertFalse(result["success"])
        self.assertIsNone(result["native_exit_code"])
        self.assertIn("cwd is not a directory", result["stderr"])
        self.assertNotIn("sentinel", result["stdout"])
        self.assertEqual(result["cleanup"]["status"], "not-needed")

    def test_missing_executable_does_not_run_code(self):
        with mock.patch.dict(
            os.environ,
            {"MCP_POWERSHELL_EXECUTABLE": "D:/no-such-pwsh.exe", "MCP_POWERSHELL_PROFILE": " "},
            clear=True,
        ):
            result = server._run_powershell("Write-Output 'sentinel'")
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertNotIn("sentinel", result["stdout"])
        self.assertIn("not found", result["stderr"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_missing_profile_blocks_user_code(self):
        with mock.patch.dict(
            os.environ,
            {
                "MCP_POWERSHELL_EXECUTABLE": "",
                "MCP_POWERSHELL_PROFILE": str(FIXTURES / "missing-profile.ps1"),
            },
            clear=True,
        ):
            result = server._run_powershell("Write-Output 'sentinel'", timeout_seconds=30)
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertNotIn("sentinel", result["stdout"])
        self.assertIn("profile not found", result["stderr"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_bad_profile_blocks_user_code(self):
        with mock.patch.dict(
            os.environ,
            {
                "MCP_POWERSHELL_EXECUTABLE": "",
                "MCP_POWERSHELL_PROFILE": str(FIXTURES / "bad-profile.ps1"),
            },
            clear=True,
        ):
            result = server._run_powershell("Write-Output 'sentinel'", timeout_seconds=30)
        self.assertFalse(result["success"])
        self.assertNotIn("sentinel", result["stdout"])
        self.assertIn("intentional-bad-profile", result["stderr"])

    def test_zero_timeout_without_unbounded_is_rejected(self):
        result = server._run_powershell("Write-Output 'sentinel'", timeout_seconds=0)
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertNotIn("sentinel", result["stdout"])
        self.assertIn("timeout_seconds must be > 0", result["stderr"])

    def test_output_directory_must_not_exist(self):
        with tempfile.TemporaryDirectory() as existing:
            result = server._run_powershell(
                "Write-Output 'sentinel'", output_directory=existing
            )
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertIn("already exists", result["stderr"])
        self.assertNotIn("sentinel", result["stdout"])

    def test_output_directory_under_project_is_rejected(self):
        target = server.MCP_ROOT / f"tmp-out-{uuid.uuid4().hex}"
        result = server._run_powershell(
            "Write-Output 'sentinel'", output_directory=str(target)
        )
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertIn("must not be under", result["stderr"])
        self.assertFalse(target.exists())

    def test_omitted_timeout_records_default_effective(self):
        result = server._run_powershell(
            "Write-Output 'sentinel'", cwd="D:/no-such-cwd-pwsh-exec"
        )
        self.assertIsNone(result["timeout_seconds_requested"])
        self.assertEqual(
            result["timeout_seconds_effective"], invocation.DEFAULT_TIMEOUT_SECONDS
        )

    def test_unbounded_records_null_effective_timeout(self):
        result = server._run_powershell(
            "Write-Output 'sentinel'",
            cwd="D:/no-such-cwd-pwsh-exec",
            unbounded=True,
        )
        self.assertIsNone(result["timeout_seconds_effective"])

    def test_version_floor_comparison_uses_major_minor_only(self):
        self.assertTrue(invocation.meets_runtime_floor((7, 5)))
        self.assertTrue(invocation.meets_runtime_floor((7, 5, 0)))
        self.assertTrue(invocation.meets_runtime_floor((7, 6, 4)))
        self.assertFalse(invocation.meets_runtime_floor((7, 4, 99)))
        self.assertFalse(invocation.meets_runtime_floor((7,)))

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_runtime_below_floor_is_rejected_before_user_code(self):
        with mock.patch(
            "invocation.probe_powershell", return_value=("7.4.6", ".NET 8.0")
        ):
            with mock.patch.dict(
                os.environ,
                {
                    "MCP_POWERSHELL_EXECUTABLE": "",
                    "MCP_POWERSHELL_PROFILE": " ",
                },
                clear=True,
            ):
                result = server._run_powershell(
                    "Write-Output 'sentinel'", timeout_seconds=30
                )
        self.assertEqual(result["outcome"], "failed-to-launch")
        self.assertNotIn("sentinel", result["stdout"])
        self.assertIn("below required 7.5", result["stderr"])
        self.assertEqual(result["powershell"]["version"], "7.4.6")

    @unittest.skipUnless(
        _have_runtime()
        and os.environ.get("MCP_POWERSHELL_7_5")
        and Path(os.environ["MCP_POWERSHELL_7_5"]).is_file(),
        "PowerShell 7.5 executable is not provided",
    )
    def test_powershell_7_5_reports_identity(self):
        executable = os.environ["MCP_POWERSHELL_7_5"]
        with mock.patch.dict(
            os.environ,
            {
                "MCP_POWERSHELL_EXECUTABLE": executable,
                "MCP_POWERSHELL_PROFILE": " ",
            },
            clear=True,
        ):
            result = server._run_powershell(
                "$PSVersionTable.PSVersion.ToString()", timeout_seconds=30
            )
        self.assertTrue(result["success"])
        self.assertTrue(result["powershell"]["version"].startswith("7.5"))
        self.assertTrue(result["stdout"].strip().startswith("7.5"))


class PowerShellMcpIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(
        _have_runtime() and _have_owned_python(),
        "the bundled PowerShell and owned Python interpreter are not installed",
    )
    def test_stdio_server_runs_from_outside_project_directory(self):
        initialization, tools, result = asyncio.run(self._call_over_stdio())

        self.assertEqual(initialization.serverInfo.name, "pwsh_exec")
        self.assertEqual([tool.name for tool in tools.tools], ["run_powershell"])
        self.assertFalse(result.isError)
        payload = result.structuredContent
        self.assertIsNotNone(payload)
        self.assertEqual(payload["stdout"].strip(), "7.6.4")
        self.assertTrue(payload["success"])
        self.assertEqual(payload["schema"], invocation.RESULT_SCHEMA)

    @unittest.skipUnless(
        _have_runtime() and _have_owned_python(),
        "the bundled PowerShell and owned Python interpreter are not installed",
    )
    def test_stdio_nonzero_exit_keeps_structured_payload(self):
        result = asyncio.run(
            self._call_over_stdio_code("Write-Output 'report'; exit 7")
        )
        self.assertTrue(result.isError)
        payload = result.structuredContent
        self.assertEqual(payload["native_exit_code"], 7)
        self.assertIn("report", payload["stdout"])
        self.assertEqual(payload["outcome"], "exited")
        self.assertFalse(payload["success"])
        text = json.loads(result.content[0].text)
        self.assertEqual(text["native_exit_code"], 7)

    def _stdio_parameters(self):
        environment = os.environ.copy()
        environment.pop(server.POWERSHELL_EXECUTABLE_ENV_VAR, None)
        environment.pop(server.POWERSHELL_PROFILE_ENV_VAR, None)
        return StdioServerParameters(
            command=str(owned_python()),
            args=["-B", str(server.MCP_ROOT / "server.py")],
            cwd=server.MCP_ROOT.parent,
            env=environment,
        )

    async def _call_over_stdio(self):
        async with stdio_client(self._stdio_parameters()) as (read_stream, write_stream):
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

    async def _call_over_stdio_code(self, code: str) -> CallToolResult:
        async with stdio_client(self._stdio_parameters()) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                return await session.call_tool(
                    "run_powershell",
                    {"code": code, "timeout_seconds": 30},
                )


class PowerShellSupervisionTests(unittest.TestCase):
    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_timeout_kills_descendant_and_keeps_partial_stdout(self):
        result = server._run_powershell(
            "Write-Output 'before'; Start-Sleep -Seconds 30; Write-Output 'after'",
            timeout_seconds=2,
        )
        self.assertEqual(result["outcome"], "timed-out")
        self.assertFalse(result["success"])
        self.assertIn("before", result["stdout"])
        self.assertNotIn("after", result["stdout"])
        self.assertEqual(result["cleanup"]["status"], "complete")
        if os.name == "nt":
            self.assertEqual(result["cleanup"]["job_object"], "assigned")
            self.assertTrue(result["cleanup"]["kill_on_job_close"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_timeout_during_profile_keeps_partial_output(self):
        with mock.patch.dict(
            os.environ,
            {
                "MCP_POWERSHELL_EXECUTABLE": "",
                "MCP_POWERSHELL_PROFILE": str(FIXTURES / "sleep-profile.ps1"),
            },
            clear=True,
        ):
            result = server._run_powershell(
                "Write-Output 'user-sentinel'", timeout_seconds=2
            )
        self.assertEqual(result["outcome"], "timed-out")
        self.assertIn("profile-start", result["stdout"])
        self.assertNotIn("profile-end", result["stdout"])
        self.assertNotIn("user-sentinel", result["stdout"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_cancel_event_stops_child(self):
        cancel = threading.Event()
        ready = Path(tempfile.gettempdir()) / f"pwsh-exec-ready-{uuid.uuid4().hex}.txt"
        code = (
            f"[IO.File]::WriteAllText({json.dumps(str(ready))}, $PID.ToString()); "
            "Start-Sleep -Seconds 30"
        )

        def worker():
            nonlocal result
            result = server._run_powershell(
                code, timeout_seconds=30, cancel_event=cancel
            )

        result = None
        thread = threading.Thread(target=worker)
        thread.start()
        for _ in range(50):
            if ready.exists() and ready.stat().st_size > 0:
                break
            thread.join(timeout=0.1)
        self.assertTrue(ready.exists())
        child_pid = int(ready.read_text(encoding="utf-8").strip())
        cancel.set()
        thread.join(timeout=15)
        self.assertIsNotNone(result)
        self.assertEqual(result["outcome"], "cancelled")
        self.assertFalse(result["success"])
        self.assertFalse(pid_is_running(child_pid))
        ready.unlink(missing_ok=True)

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_grandchild_is_reaped_unrelated_sentinel_survives(self):
        sentinel = subprocess_sleeper()
        try:
            result = server._run_powershell(
                r"""
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $PSHOME 'pwsh.exe'
$psi.Arguments = '-NoProfile -Command Start-Sleep -Seconds 60'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$child = [System.Diagnostics.Process]::Start($psi)
Write-Output ("GRANDCHILD=" + $child.Id)
Start-Sleep -Seconds 60
""",
                timeout_seconds=2,
            )
            self.assertEqual(result["outcome"], "timed-out")
            line = next(
                part
                for part in result["stdout"].splitlines()
                if part.startswith("GRANDCHILD=")
            )
            grandchild = int(line.split("=", 1)[1])
            self.assertFalse(pid_is_running(grandchild))
            self.assertTrue(pid_is_running(sentinel.pid))
            self.assertEqual(result["cleanup"]["status"], "complete")
        finally:
            kill_pid(sentinel.pid)
            try:
                sentinel.wait(timeout=5)
            except Exception:
                pass

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_unicode_quotes_and_spaces_in_cwd_and_code(self):
        with tempfile.TemporaryDirectory(prefix="pwsh exec ") as raw:
            work = Path(raw) / "café dir"
            work.mkdir()
            profile_dir = Path(raw) / "client's profile"
            profile_dir.mkdir()
            profile = profile_dir / "profile.ps1"
            profile.write_text(
                "$env:MCP_POWERSHELL_PROFILE_TEST_VALUE = 'profile-loaded'\n"
                "function Get-McpPowerShellProfileTestValue { $env:MCP_POWERSHELL_PROFILE_TEST_VALUE }\n",
                encoding="utf-8",
            )
            with mock.patch.dict(
                os.environ,
                {
                    "MCP_POWERSHELL_EXECUTABLE": "",
                    "MCP_POWERSHELL_PROFILE": str(profile),
                },
                clear=True,
            ):
                result = server._run_powershell(
                    "Write-Output \"quote'test café 日本語\"",
                    cwd=str(work),
                    timeout_seconds=30,
                )
            self.assertTrue(result["success"], result["stderr"])
            self.assertIn("quote'test café 日本語", result["stdout"])
            self.assertEqual(Path(result["cwd"]), work.resolve())

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_simultaneous_large_streams_do_not_deadlock(self):
        result = server._run_powershell(
            "$block = 'A' * 4096; $err = 'B' * 4096; "
            "1..400 | ForEach-Object { [Console]::Out.Write($block); [Console]::Error.Write($err) }",
            timeout_seconds=30,
        )
        self.assertEqual(result["outcome"], "exited")
        self.assertEqual(result["native_exit_code"], 0)
        self.assertTrue(result["capture"]["stdout_truncated"])
        self.assertTrue(result["capture"]["stderr_truncated"])
        self.assertGreater(result["capture"]["stdout_bytes_observed"], 1_000_000)
        self.assertGreater(result["capture"]["stderr_bytes_observed"], 1_000_000)
        self.assertLessEqual(
            result["capture"]["stdout_bytes_retained"]
            + result["capture"]["stderr_bytes_retained"],
            invocation.COMBINED_MEMORY_LIMIT,
        )
        self.assertIn("A", result["stdout"])
        self.assertIn("B", result["stderr"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_output_directory_writes_streams_and_result(self):
        out = Path(tempfile.gettempdir()) / f"pwsh-exec-out-{uuid.uuid4().hex}"
        result = server._run_powershell(
            "[Console]::Error.WriteLine('err'); Write-Output 'ok'",
            timeout_seconds=30,
            output_directory=str(out),
        )
        self.assertTrue(result["success"])
        self.assertTrue((out / "stdout.bin").is_file())
        self.assertTrue((out / "stderr.bin").is_file())
        self.assertTrue((out / "result.json").is_file())
        saved = json.loads((out / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["id"], result["id"])
        self.assertIn("ok", (out / "stdout.bin").read_text(encoding="utf-8"))
        self.assertIn("err", (out / "stderr.bin").read_text(encoding="utf-8"))

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_failed_kill_preserves_timeout_outcome(self):
        ready = Path(tempfile.gettempdir()) / f"pwsh-exec-killfail-{uuid.uuid4().hex}.txt"
        def fake_kill(process, job):
            return ["kill skipped"]

        result = invocation.run(
            f"[IO.File]::WriteAllText({json.dumps(str(ready))}, $PID.ToString()); Start-Sleep -Seconds 20",
            executable=str(server.DEFAULT_POWERSHELL_EXECUTABLE),
            profile=None,
            cwd=Path.cwd(),
            timeout_seconds=1,
            unbounded=False,
            output_directory=None,
            mcp_root=server.MCP_ROOT,
            cleanup_seconds=1,
            kill_tree=fake_kill,
        )
        self.assertEqual(result["outcome"], "timed-out")
        self.assertFalse(result["success"])
        self.assertEqual(result["cleanup"]["status"], "incomplete")
        self.assertIn("kill skipped", result["cleanup"]["diagnostics"])
        self.assertTrue(ready.is_file())
        leaked = int(ready.read_text(encoding="utf-8").strip())
        kill_pid(leaked)
        ready.unlink(missing_ok=True)
        follow = server._run_powershell("Write-Output 'next'", timeout_seconds=15)
        self.assertTrue(follow["success"])

    @unittest.skipUnless(_have_runtime(), "the bundled PowerShell runtime is not installed")
    def test_next_call_after_timeout_uses_fresh_state(self):
        first = server._run_powershell("Start-Sleep -Seconds 20", timeout_seconds=1)
        self.assertEqual(first["outcome"], "timed-out")
        second = server._run_powershell("Write-Output 'after-timeout'", timeout_seconds=15)
        self.assertTrue(second["success"])
        self.assertEqual(second["stdout"].strip(), "after-timeout")
        self.assertNotEqual(first["id"], second["id"])

    @unittest.skipUnless(
        _have_runtime() and _have_owned_python(),
        "the bundled PowerShell and owned Python interpreter are not installed",
    )
    def test_mcp_cancel_stops_owned_process(self):
        asyncio.run(self._mcp_cancel())

    async def _mcp_cancel(self):
        ready = Path(tempfile.gettempdir()) / f"pwsh-exec-mcp-ready-{uuid.uuid4().hex}.txt"
        environment = os.environ.copy()
        environment.pop(server.POWERSHELL_EXECUTABLE_ENV_VAR, None)
        environment["MCP_POWERSHELL_PROFILE"] = " "
        parameters = StdioServerParameters(
            command=str(owned_python()),
            args=["-B", str(server.MCP_ROOT / "server.py")],
            cwd=server.MCP_ROOT.parent,
            env=environment,
        )
        async with stdio_client(parameters) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                request_id = session._request_id
                code = (
                    f"[IO.File]::WriteAllText({json.dumps(str(ready))}, $PID.ToString()); "
                    "Start-Sleep -Seconds 30"
                )
                call = asyncio.create_task(
                    session.call_tool(
                        "run_powershell",
                        {"code": code, "timeout_seconds": 30},
                    )
                )
                for _ in range(80):
                    if ready.exists() and ready.stat().st_size > 0:
                        break
                    await asyncio.sleep(0.1)
                self.assertTrue(ready.exists())
                child_pid = int(ready.read_text(encoding="utf-8").strip())
                await session.send_notification(
                    ClientNotification(
                        CancelledNotification(
                            params=CancelledNotificationParams(
                                requestId=request_id, reason="test"
                            )
                        )
                    )
                )
                try:
                    await asyncio.wait_for(call, timeout=15)
                except Exception:
                    pass
                for _ in range(50):
                    if not pid_is_running(child_pid):
                        break
                    await asyncio.sleep(0.1)
                self.assertFalse(pid_is_running(child_pid))
        ready.unlink(missing_ok=True)

    @unittest.skipUnless(
        _have_runtime() and _have_owned_python(),
        "the bundled PowerShell and owned Python interpreter are not installed",
    )
    def test_stdio_disconnect_stops_owned_process(self):
        asyncio.run(self._stdio_disconnect())

    async def _stdio_disconnect(self):
        ready = Path(tempfile.gettempdir()) / f"pwsh-exec-disc-{uuid.uuid4().hex}.txt"
        environment = os.environ.copy()
        environment.pop(server.POWERSHELL_EXECUTABLE_ENV_VAR, None)
        environment["MCP_POWERSHELL_PROFILE"] = " "
        parameters = StdioServerParameters(
            command=str(owned_python()),
            args=["-B", str(server.MCP_ROOT / "server.py")],
            cwd=server.MCP_ROOT.parent,
            env=environment,
        )
        call = None
        child_pid = None
        async with stdio_client(parameters) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                code = (
                    f"[IO.File]::WriteAllText({json.dumps(str(ready))}, $PID.ToString()); "
                    "Start-Sleep -Seconds 30"
                )
                call = asyncio.create_task(
                    session.call_tool(
                        "run_powershell",
                        {"code": code, "timeout_seconds": 30},
                    )
                )
                for _ in range(80):
                    if ready.exists() and ready.stat().st_size > 0:
                        break
                    await asyncio.sleep(0.1)
                self.assertTrue(ready.exists())
                child_pid = int(ready.read_text(encoding="utf-8").strip())
        if call is not None:
            call.cancel()
            try:
                await call
            except (asyncio.CancelledError, Exception):
                pass
        self.assertIsNotNone(child_pid)
        for _ in range(50):
            if not pid_is_running(child_pid):
                break
            await asyncio.sleep(0.1)
        self.assertFalse(pid_is_running(child_pid))
        ready.unlink(missing_ok=True)

    @unittest.skipUnless(
        _have_runtime() and _have_owned_python(),
        "the bundled PowerShell and owned Python interpreter are not installed",
    )
    def test_abrupt_parent_death_kills_job_child(self):
        pid_file = Path(tempfile.gettempdir()) / f"pwsh-exec-abrupt-{uuid.uuid4().hex}.txt"
        helper = Path(__file__).parent / "helpers" / "abrupt_job_parent.py"
        import subprocess as sp

        command = [
            str(owned_python()),
            str(helper),
            "--pid-file",
            str(pid_file),
            "--executable",
            str(server.DEFAULT_POWERSHELL_EXECUTABLE),
        ]
        proc = sp.run(command, cwd=str(server.MCP_ROOT), check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(pid_file.is_file())
        child_pid = int(pid_file.read_text(encoding="utf-8").strip())
        import time

        for _ in range(40):
            if not pid_is_running(child_pid):
                break
            time.sleep(0.1)
        self.assertFalse(pid_is_running(child_pid))
        pid_file.unlink(missing_ok=True)

    @unittest.skipUnless(_latexai_roots() is not None, "LaTeXAI checkout env is not set")
    def test_latexai_tap_failure_preserves_report(self):
        checkout = _latexai_roots()
        out = Path(tempfile.gettempdir()) / f"pwsh-exec-tap-{uuid.uuid4().hex}"
        with mock.patch.dict(
            os.environ,
            {
                **os.environ,
                "MCP_POWERSHELL_EXECUTABLE": str(server.DEFAULT_POWERSHELL_EXECUTABLE),
                "MCP_POWERSHELL_PROFILE": str(checkout / "scripts" / "profile.ps1"),
            },
        ):
            result = server._run_powershell(
                "& .\\scripts\\test-run.ps1 -Path scripts/tests/tap/fail.t "
                "-SkipGenerate -WaitTimeoutSeconds 60 -ProcessTimeoutSeconds 30",
                cwd=str(checkout),
                timeout_seconds=120,
                output_directory=str(out),
            )
        self.assertEqual(result["outcome"], "exited")
        self.assertNotEqual(result["native_exit_code"], 0)
        self.assertFalse(result["success"])
        combined = result["stdout"] + result["stderr"]
        self.assertTrue(
            "not ok" in combined
            or "intentional failure" in combined
            or "FAIL" in combined
            or "failed" in combined.lower(),
            combined[-4000:],
        )


def subprocess_sleeper():
    import subprocess

    return subprocess.Popen(
        [
            str(server.DEFAULT_POWERSHELL_EXECUTABLE),
            "-NoProfile",
            "-Command",
            "Start-Sleep -Seconds 60",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def kill_pid(pid: int) -> None:
    import subprocess

    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


if __name__ == "__main__":
    unittest.main()
