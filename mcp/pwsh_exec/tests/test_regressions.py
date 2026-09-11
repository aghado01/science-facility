import asyncio
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest import mock

import invocation
import server
from windows_job import WindowsJob, pid_is_running
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


class CaptureRegressionTests(unittest.TestCase):
    def test_head_boundary_does_not_mean_truncation(self):
        for payload in (b"1234567", "AAAA€BBBB".encode(), b"123456789012"):
            capture = invocation.StreamCapture(12, None)
            for index in range(0, len(payload), 2):
                capture.write(payload[index:index + 2])
            self.assertEqual(capture.display(), (payload, False))
            self.assertEqual(capture.retained(), payload)

    def test_actual_utf8_cut_keeps_only_complete_boundary_characters(self):
        capture = invocation.StreamCapture(12, None)
        capture.write(("AAAA€" + "discarded" * 5 + "€BBBB").encode())
        data, truncated = capture.display()
        self.assertTrue(truncated)
        self.assertEqual(data.decode("utf-8"), "AAAA\n...<truncated>...\nBBBB")
        self.assertLessEqual(len(capture.retained()), 12)


@unittest.skipUnless(server.DEFAULT_POWERSHELL_EXECUTABLE.is_file(), "bundled PowerShell required")
class InvocationRegressionTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(os.environ, {"MCP_POWERSHELL_PROFILE": ""})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_existing_output_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("result.json", "stdout.bin", "stderr.bin"):
                (root / name).write_bytes(b"original\x00evidence")
            result = server._run_powershell("'must not run'", output_directory=directory)
            self.assertEqual(result["outcome"], "failed-to-launch")
            self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()},
                             {name: b"original\x00evidence" for name in ("result.json", "stdout.bin", "stderr.bin")})

    def test_invalid_timeout_is_a_structured_failure(self):
        for budget in (float("nan"), float("inf"), -1, "invalid"):
            result = server._run_powershell("'must not run'", timeout_seconds=budget)
            self.assertEqual(result["outcome"], "failed-to-launch")

    def test_assignment_failure_never_resumes_the_child(self):
        invocation.probe_powershell(str(server.DEFAULT_POWERSHELL_EXECUTABLE))
        processes = []
        original = invocation.subprocess.Popen
        def record(*args, **kwargs):
            process = original(*args, **kwargs)
            processes.append(process)
            return process
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "executed"
            with mock.patch.object(WindowsJob, "assign", side_effect=OSError("injected admission failure")), \
                 mock.patch.object(invocation.subprocess, "Popen", side_effect=record):
                result = server._run_powershell(f"[IO.File]::WriteAllText('{marker}', 'ran')", timeout_seconds=5)
            self.assertEqual(result["outcome"], "failed-to-launch")
            self.assertFalse(marker.exists())
            self.assertTrue(processes)
            self.assertTrue(all(not pid_is_running(p.pid) for p in processes))
            self.assertEqual(result["cleanup"]["status"], "complete")

    def test_background_polling_and_cancellation(self):
        async def scenario(root):
            started = (await server.start_powershell("'started'; Start-Sleep 30", str(root / "run"), 20)).structuredContent
            pending = (await server.wait_powershell(started["id"])).structuredContent
            self.assertEqual(pending["state"], "running")
            await asyncio.sleep(1)
            await server.cancel_powershell(started["id"])
            done = (await server.wait_powershell(started["id"], 20)).structuredContent
            self.assertEqual(done["state"], "completed")
            self.assertEqual(done["result"]["outcome"], "cancelled")
            self.assertEqual(done["result"]["cleanup"]["status"], "complete")
            self.assertEqual(json.loads(Path(done["result_path"]).read_text())["outcome"], "cancelled")
        with tempfile.TemporaryDirectory() as directory:
            asyncio.run(scenario(Path(directory)))

    def test_background_timeout_is_owned_by_the_starting_caller(self):
        async def scenario(root):
            started = (await server.start_powershell("'partial'; Start-Sleep 30", str(root / "run"), 2)).structuredContent
            done = (await server.wait_powershell(started["id"], 20)).structuredContent
            self.assertEqual(done["result"]["outcome"], "timed-out")
            self.assertEqual(done["result"]["timeout_seconds_effective"], 2)
            self.assertIn("partial", done["result"]["stdout"])
        with tempfile.TemporaryDirectory() as directory:
            asyncio.run(scenario(Path(directory)))

    def test_started_job_has_structured_stdio_responses(self):
        async def scenario(root):
            parameters = StdioServerParameters(command=sys.executable,
                args=["-B", str(server.MCP_ROOT / "server.py")], env=os.environ.copy())
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams) as session:
                    await session.initialize()
                    started = await session.call_tool("start_powershell", {
                        "code": "'report'; exit 7", "output_directory": str(root / "run"), "timeout_seconds": 10})
                    self.assertFalse(started.isError)
                    done = await session.call_tool("wait_powershell", {
                        "id": started.structuredContent["id"], "wait_seconds": 10})
                    self.assertTrue(done.isError)
                    self.assertEqual(done.structuredContent["result"]["native_exit_code"], 7)
                    self.assertNotIn("result", json.loads(done.content[0].text))
        with tempfile.TemporaryDirectory() as directory:
            asyncio.run(scenario(Path(directory)))


if __name__ == "__main__":
    unittest.main()
