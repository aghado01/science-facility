"""MCP server for executing PowerShell in a configured runtime."""

from __future__ import annotations

import atexit
import asyncio
import json
import math
import os
import threading
import uuid
from concurrent.futures import Future, ThreadPoolExecutor
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
_JOBS: dict[str, tuple[Future, threading.Event, str]] = {}
_JOBS_LOCK = threading.Lock()
_JOB_POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="pwsh-invocation")

FastMCPSettings.model_rebuild()


def _shutdown() -> None:
    with _JOBS_LOCK:
        for _, stop, _ in _JOBS.values():
            stop.set()
    invocation.shutdown_in_flight()


@asynccontextmanager
async def _lifespan(_server: FastMCP):
    try:
        yield {}
    finally:
        _shutdown()


atexit.register(_shutdown)
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


def _job_response(status: dict) -> CallToolResult:
    result = status.get("result")
    pointer = {key: value for key, value in status.items() if key != "result"}
    if result:
        pointer.update(outcome=result["outcome"], success=result["success"])
    return CallToolResult(content=[TextContent(type="text", text=json.dumps(pointer))],
                          structuredContent=status, isError=bool(result and not result["success"]))


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
    """Run a short command synchronously. For work exceeding the client's request deadline,
    use start_powershell and wait_powershell; timeout_seconds cannot extend that deadline.
    """
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
        result = await asyncio.shield(future)
    except BaseException as exc:
        if not _is_cancel(exc):
            raise
        cancel_event.set()
        import anyio

        with anyio.CancelScope(shield=True):
            await asyncio.shield(future)
        # MCP cancellation already completed the request. The result is durable;
        # attempting a second response here would tear down the stdio session.
        raise
    return _to_call_tool_result(result)


@mcp.tool()
async def start_powershell(
    code: str,
    output_directory: str,
    timeout_seconds: float | None = None,
    cwd: str | None = None,
    unbounded: bool = False,
) -> CallToolResult:
    """Start server-owned work without holding an MCP request open. Supply a finite positive
    timeout_seconds (or explicit unbounded=True) and a new output directory. Poll with
    wait_powershell. Server shutdown cancels the work and cleans up its process tree.
    """
    if not unbounded and (
        timeout_seconds is None or not math.isfinite(timeout_seconds) or timeout_seconds <= 0
    ):
        raise ValueError("Supply a finite positive timeout_seconds or unbounded=True")
    if not output_directory or not Path(output_directory).is_absolute():
        raise ValueError("output_directory must be an absolute path to a new directory")
    stop = threading.Event()
    job_id = uuid.uuid4().hex
    with _JOBS_LOCK:
        if sum(not entry[0].done() for entry in _JOBS.values()) >= 8:
            raise ValueError("Eight invocations are already active; wait for one to finish")
        # Completed results remain on disk. Keep only a bounded in-memory lookup window.
        for old_id in list(_JOBS):
            if len(_JOBS) < 128:
                break
            if _JOBS[old_id][0].done():
                del _JOBS[old_id]
        future = _JOB_POOL.submit(
            _run_powershell, code, cwd, timeout_seconds, output_directory, unbounded, stop
        )
        _JOBS[job_id] = (future, stop, str(Path(output_directory) / "result.json"))
    return _job_response({"schema": "pwsh_exec/job/0.1", "id": job_id, "state": "running",
            "result_path": str(Path(output_directory) / "result.json"),
            "timeout_seconds_effective": None if unbounded else timeout_seconds})


@mcp.tool()
async def wait_powershell(id: str, wait_seconds: float = 0) -> CallToolResult:
    """Read a started invocation, optionally waiting at most 20 seconds. A running response
    does not cancel work or change its deadline. Completed responses include the invocation
    result; full streams and result.json are saved in the caller's output directory.
    """
    if not math.isfinite(wait_seconds) or not 0 <= wait_seconds <= 20:
        raise ValueError("wait_seconds must be finite and between 0 and 20")
    with _JOBS_LOCK:
        entry = _JOBS.get(id)
    if entry is None:
        raise ValueError("Unknown or expired invocation id; use its saved result.json")
    future, _, result_path = entry
    if not future.done() and wait_seconds:
        try:
            await asyncio.wait_for(asyncio.shield(asyncio.wrap_future(future)), wait_seconds)
        except TimeoutError:
            pass
    response = {"schema": "pwsh_exec/job/0.1", "id": id,
                "state": "completed" if future.done() else "running",
                "result_path": result_path}
    if future.done():
        response["result"] = future.result()
        response["result_path"] = response["result"]["capture"].get("result_path")
    return _job_response(response)


@mcp.tool()
async def cancel_powershell(id: str) -> CallToolResult:
    """Request cancellation of a started invocation. Use wait_powershell to confirm cleanup
    and retrieve the terminal result. Cancellation never extends its execution budget.
    """
    with _JOBS_LOCK:
        entry = _JOBS.get(id)
    if entry is None:
        raise ValueError("Unknown or expired invocation id")
    entry[1].set()
    return await wait_powershell(id)


if __name__ == "__main__":
    mcp.run()
