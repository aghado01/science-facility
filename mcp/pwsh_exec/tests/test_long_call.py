"""Opt-in actual stdio qualification beyond a typical client's 60-second deadline."""
import asyncio
from datetime import timedelta
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import server


@unittest.skipUnless(os.environ.get("PWSH_EXEC_LONG_PROBE") == "1", "set PWSH_EXEC_LONG_PROBE=1 for 65-second stdio qualification")
class LongCallTests(unittest.TestCase):
    def test_caller_budget_outlives_individual_transport_requests(self):
        async def scenario(directory):
            parameters = StdioServerParameters(command=sys.executable,
                args=["-B", str(server.MCP_ROOT / "server.py")],
                env={**os.environ, "MCP_POWERSHELL_PROFILE": ""}, cwd=str(server.MCP_ROOT))
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams, read_timeout_seconds=timedelta(seconds=5)) as session:
                    await session.initialize()
                    clock = time.monotonic()
                    started = await session.call_tool("start_powershell", {
                        "code": "'before'; Start-Sleep 65; 'after'", "timeout_seconds": 80,
                        "output_directory": str(Path(directory) / "run")})
                    self.assertFalse(started.isError)
                    job = started.structuredContent
                    while time.monotonic() - clock < 90:
                        response = await session.call_tool("wait_powershell", {"id": job["id"], "wait_seconds": 2})
                        self.assertFalse(response.isError)
                        status = response.structuredContent
                        if status["state"] == "completed":
                            break
                    else:
                        await session.call_tool("cancel_powershell", {"id": job["id"]})
                        self.fail("work did not finish within the qualification budget")
                    self.assertGreaterEqual(time.monotonic() - clock, 65)
                    self.assertTrue(status["result"]["success"])
                    self.assertIn("after", status["result"]["stdout"])
                    self.assertEqual(status["result"]["timeout_seconds_effective"], 80)
                    self.assertEqual(status["result"]["cleanup"]["status"], "complete")
                    self.assertTrue(Path(status["result_path"]).is_file())
        with tempfile.TemporaryDirectory() as directory:
            asyncio.run(scenario(directory))


if __name__ == "__main__":
    unittest.main()
