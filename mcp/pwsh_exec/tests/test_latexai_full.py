"""Opt-in full TAP consumer qualification through the actual start/wait MCP protocol."""
import asyncio
from datetime import timedelta
import json
import os
from pathlib import Path
import sys
import time
import unittest
import uuid
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import server


@unittest.skipUnless(os.environ.get("PWSH_EXEC_FULL_LATEXAI") == "1", "set PWSH_EXEC_FULL_LATEXAI=1 and LATEXAI_ROOT for full TAP qualification")
class LaTeXAIFullTests(unittest.TestCase):
    def test_full_suite_through_caller_owned_timeout(self):
        root = Path(os.environ["LATEXAI_ROOT"])
        run = root / "temp" / "t" / "infra-review" / uuid.uuid4().hex
        run.mkdir(parents=True)
        code = ("& './scripts/test-run.ps1' -Selection full -MaxWorkers 6 "
                "-ExecutionTimeoutSeconds 600 -CleanupTimeoutSeconds 15 "
                f"-RunDirectory '{str(run / 'tap').replace(chr(39), chr(39) * 2)}' "
                "| Select-Object Summary,Cleanup,Errors | ConvertTo-Json -Depth 5")
        async def scenario():
            parameters = StdioServerParameters(command=sys.executable,
                args=["-B", str(server.MCP_ROOT / "server.py")],
                env={**os.environ, "MCP_POWERSHELL_PROFILE": str(root / "scripts" / "profile.ps1")})
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams, read_timeout_seconds=timedelta(seconds=30)) as session:
                    await session.initialize()
                    started = await session.call_tool("start_powershell", {"code": code,
                        "cwd": str(root), "output_directory": str(run / "mcp"), "timeout_seconds": 750})
                    self.assertFalse(started.isError)
                    job_id = started.structuredContent["id"]
                    clock = time.monotonic()
                    while time.monotonic() - clock < 800:
                        response = await session.call_tool("wait_powershell", {"id": job_id, "wait_seconds": 20})
                        state = response.structuredContent
                        if state["state"] == "completed":
                            break
                    else:
                        await session.call_tool("cancel_powershell", {"id": job_id})
                        self.fail("qualification wait budget expired")
                    print(f"LaTeXAI evidence: {run}", flush=True)
                    self.assertTrue(state["result"]["success"], state["result"]["stderr"])
                    report = json.loads((run / "tap" / "execution.json").read_text())
                    self.assertEqual(report["summary"]["Total"], report["summary"]["Succeeded"])
                    self.assertEqual(report["missingResults"], 0)
                    self.assertEqual(report["cleanup"]["State"], "Confirmed")
                    print(json.dumps(report["summary"]), flush=True)
        asyncio.run(scenario())
