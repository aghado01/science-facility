"""Run a bounded qualification command through a fresh start/wait MCP connection."""
import argparse
import asyncio
from datetime import timedelta
import json
import os
from pathlib import Path
import sys
import time
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

MCP_ROOT = Path(__file__).resolve().parents[1]


async def run(args):
    parameters = StdioServerParameters(command=sys.executable,
        args=["-B", str(MCP_ROOT / "server.py")],
        env={**os.environ, "MCP_POWERSHELL_PROFILE": args.profile})
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams, read_timeout_seconds=timedelta(seconds=30)) as session:
            await session.initialize()
            start = await session.call_tool("start_powershell", {"code": args.code,
                "cwd": args.cwd, "timeout_seconds": args.timeout_seconds,
                "output_directory": args.output_directory})
            if start.isError:
                raise RuntimeError(start.content)
            job_id = start.structuredContent["id"]
            print(json.dumps(start.structuredContent), flush=True)
            deadline = time.monotonic() + args.timeout_seconds + 60
            while time.monotonic() < deadline:
                response = await session.call_tool("wait_powershell", {"id": job_id, "wait_seconds": 20})
                status = response.structuredContent
                if status["state"] == "completed":
                    result = status["result"]
                    print(json.dumps({"success": result["success"], "outcome": result["outcome"],
                        "result_path": status["result_path"], "stdout": result["stdout"]}), flush=True)
                    return 0 if result["success"] else 1
            await session.call_tool("cancel_powershell", {"id": job_id})
            raise TimeoutError("qualification caller deadline expired")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--code", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--profile", default="")
    sys.exit(asyncio.run(run(parser.parse_args())))
