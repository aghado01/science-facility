"""MCP server for executing PowerShell in a configured runtime."""

from __future__ import annotations

import atexit
import asyncio
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import Settings as FastMCPSettings
from mcp.types import CallToolResult, TextContent

import invocation


POWERSHELL_EXECUTABLE_ENV_VAR = "MCP_POWERSHELL_EXECUTABLE"
POWERSHELL_PROFILE_ENV_VAR = "MCP_POWERSHELL_PROFILE"
MCP_ROOT = Path(__file__).resolve().parent
DEFAULT_POWERSHELL_EXECUTABLE = MCP_ROOT / "deps" / "bin" / "pwsh" / "pwsh.exe"
DEFAULT_POWERSHELL_PROFILE = MCP_ROOT / "scripts" / "pwsh" / "profile-pwsh.ps1"
_SERVER_CWD = Path.cwd()
_COMPACT_TEXT_LIMIT = 64 * 1024

FastMCPSettings.model_rebuild()


@asynccontextmanager
async def _lifespan(_server: FastMCP):
    try:
        yield {}
    finally:
        invocation.shutdown_in_flight()


atexit.register(invocation.shutdown_in_flight)
mcp = FastMCP("pwsh_exec", lifespan=_lifespan)


def _resolve_powershell_executable() -> str:
    configured = os.environ.get(POWERSHELL_EXECUTABLE_ENV_VAR)
    if configured and configured.strip():
        candidate = Path(configured.strip())
        if candidate.is_file():
            return str(candidate.resolve())
        return configured.strip()
    return str(DEFAULT_POWERSHELL_EXECUTABLE)


def _resolve_powershell_profile() -> str | None:
    configured = os.environ.get(POWERSHELL_PROFILE_ENV_VAR)
    if configured is not None:
        if not configured.strip():
            return None
        candidate = Path(configured.strip())
        if candidate.is_file():
            return str(candidate.resolve())
        return configured.strip()
    if DEFAULT_POWERSHELL_PROFILE.is_file():
        return str(DEFAULT_POWERSHELL_PROFILE)
    return None


def _build_powershell_code(code: str) -> str:
    return invocation.build_powershell_script(code)


def _resolve_cwd(cwd: str | None) -> Path:
    if cwd is None:
        return _SERVER_CWD
    return Path(cwd)


def _text_payload(result: dict) -> str:
    capture = result.get("capture") or {}
    observed = int(capture.get("stdout_bytes_observed") or 0) + int(
        capture.get("stderr_bytes_observed") or 0
    )
    result_path = capture.get("result_path")
    if result_path or observed > _COMPACT_TEXT_LIMIT:
        pointer = {
            "schema": result.get("schema"),
            "id": result.get("id"),
            "outcome": result.get("outcome"),
            "success": result.get("success"),
            "native_exit_code": result.get("native_exit_code"),
            "output_directory": str(Path(result_path).parent) if result_path else None,
            "result_path": result_path,
            "stdout_bytes_observed": capture.get("stdout_bytes_observed"),
            "stderr_bytes_observed": capture.get("stderr_bytes_observed"),
            "cleanup": (result.get("cleanup") or {}).get("status"),
        }
        return json.dumps(pointer, indent=2)
    return json.dumps(result, indent=2)


def _to_call_tool_result(result: dict) -> CallToolResult:
    return CallToolResult(
        content=[TextContent(type="text", text=_text_payload(result))],
        structuredContent=result,
        isError=not bool(result.get("success")),
    )


def _is_cancel(exc: BaseException) -> bool:
    if isinstance(exc, asyncio.CancelledError):
        return True
    try:
        import anyio

        return isinstance(exc, anyio.get_cancelled_exc_class())
    except Exception:
        return False


def _run_powershell(
    code: str,
    cwd: str | None = None,
    timeout_seconds: float | None = None,
    output_directory: str | None = None,
    unbounded: bool = False,
    cancel_event=None,
) -> dict:
    return invocation.run(
        code,
        executable=_resolve_powershell_executable(),
        profile=_resolve_powershell_profile(),
        cwd=_resolve_cwd(cwd),
        timeout_seconds=timeout_seconds,
        unbounded=unbounded,
        output_directory=output_directory,
        mcp_root=MCP_ROOT,
        cancel_event=cancel_event,
    )


@mcp.tool()
async def run_powershell(
    code: str,
    cwd: str | None = None,
    timeout_seconds: float | None = None,
    output_directory: str | None = None,
    unbounded: bool = False,
) -> CallToolResult:
    """Run PowerShell in a fresh process and return stdout, stderr, exit status and limits."""
    import threading

    cancel_event = threading.Event()
    loop = asyncio.get_running_loop()
    future = loop.run_in_executor(
        None,
        lambda: _run_powershell(
            code,
            cwd=cwd,
            timeout_seconds=timeout_seconds,
            output_directory=output_directory,
            unbounded=unbounded,
            cancel_event=cancel_event,
        ),
    )
    try:
        result = await future
    except BaseException as exc:
        if not _is_cancel(exc):
            raise
        cancel_event.set()
        result = await asyncio.shield(future)
        return _to_call_tool_result(result)
    return _to_call_tool_result(result)


if __name__ == "__main__":
    mcp.run()
