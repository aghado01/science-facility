"""MCP server for executing PowerShell in a configured runtime."""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import Settings as FastMCPSettings

POWERSHELL_EXECUTABLE_ENV_VAR = "MCP_POWERSHELL_EXECUTABLE"
POWERSHELL_PROFILE_ENV_VAR = "MCP_POWERSHELL_PROFILE"
MCP_ROOT = Path(__file__).resolve().parent
DEFAULT_POWERSHELL_EXECUTABLE = MCP_ROOT / "deps" / "bin" / "pwsh" / "pwsh.exe"
DEFAULT_POWERSHELL_PROFILE = MCP_ROOT / "scripts" / "pwsh" / "profile-pwsh.ps1"
RESULT_SCHEMA = "pwsh_exec/invocation/0.1"
MINIMUM_PS_VERSION = (7, 5)
DEFAULT_TIMEOUT_SECONDS = 7800.0
DEFAULT_CLEANUP_SECONDS = 30.0
MEMORY_CAPTURE_LIMIT = 2 * 1024 * 1024
_VERSION_CACHE: dict[str, tuple[str, str]] = {}
_SERVER_CWD = Path.cwd()

FastMCPSettings.model_rebuild()
mcp = FastMCP("pwsh_exec")


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
    commands = [
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
        "$OutputEncoding = [Console]::OutputEncoding; "
        f"if ($env:{POWERSHELL_PROFILE_ENV_VAR} -and $env:{POWERSHELL_PROFILE_ENV_VAR}.Trim()) {{ "
        f"$__mcpPowerShellProfile = (Resolve-Path -LiteralPath $env:{POWERSHELL_PROFILE_ENV_VAR} -ErrorAction Stop).ProviderPath; "
        "$null = . $__mcpPowerShellProfile; "
        "Remove-Variable __mcpPowerShellProfile -ErrorAction SilentlyContinue; "
        "}; "
    ]
    commands.append(code)
    return "".join(commands)


def _decode(data: bytes) -> tuple[str, bool]:
    try:
        return data.decode("utf-8"), False
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace"), True


def _trim_bytes(data: bytes, limit: int = MEMORY_CAPTURE_LIMIT) -> tuple[bytes, bool]:
    if len(data) <= limit:
        return data, False
    keep = limit // 2
    return data[:keep] + b"\n...<truncated>...\n" + data[-keep:], True


class _WinJob:
    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self._k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._k32.CreateJobObjectW.restype = wintypes.HANDLE
        self._handle = self._k32.CreateJobObjectW(None, None)
        if not self._handle:
            raise OSError("CreateJobObjectW failed")
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
        JobObjectExtendedLimitInformation = 9

        class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", wintypes.LARGE_INTEGER),
                ("PerJobUserTimeLimit", wintypes.LARGE_INTEGER),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("ReadOperationCount", ctypes.c_uint64),
                ("WriteOperationCount", ctypes.c_uint64),
                ("OtherOperationCount", ctypes.c_uint64),
                ("ReadTransferCount", ctypes.c_uint64),
                ("WriteTransferCount", ctypes.c_uint64),
                ("OtherTransferCount", ctypes.c_uint64),
            ]

        class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
                ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self._k32.SetInformationJobObject(
            self._handle,
            JobObjectExtendedLimitInformation,
            ctypes.byref(info),
            ctypes.sizeof(info),
        ):
            self.close()
            raise OSError("SetInformationJobObject failed")

    def assign(self, pid: int) -> None:
        import ctypes
        from ctypes import wintypes

        PROCESS_SET_QUOTA = 0x0100
        PROCESS_TERMINATE = 0x0001
        handle = self._k32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, pid)
        if not handle:
            raise OSError("OpenProcess failed")
        try:
            if not self._k32.AssignProcessToJobObject(self._handle, handle):
                raise OSError("AssignProcessToJobObject failed")
        finally:
            self._k32.CloseHandle(handle)

    def close(self) -> None:
        if getattr(self, "_handle", None):
            self._k32.CloseHandle(self._handle)
            self._handle = None


def _kill_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        process.kill()


def _probe_powershell(executable: str) -> tuple[str, str]:
    resolved = str(Path(executable))
    cached = _VERSION_CACHE.get(resolved)
    if cached:
        return cached
    probe = subprocess.run(
        [
            executable,
            "-NoProfile",
            "-Command",
            "$PSVersionTable.PSVersion.ToString(); [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
        check=False,
    )
    lines = [line.strip() for line in (probe.stdout or "").splitlines() if line.strip()]
    version = lines[0] if lines else ""
    framework = lines[1] if len(lines) > 1 else ""
    _VERSION_CACHE[resolved] = (version, framework)
    return version, framework


def _parse_ps_version(text: str) -> tuple[int, ...]:
    parts = []
    for item in text.split("."):
        digits = "".join(ch for ch in item if ch.isdigit())
        if digits:
            parts.append(int(digits))
    return tuple(parts or [0])


@dataclass
class _Capture:
    data: bytearray
    path: Path | None
    truncated: bool = False

    def write(self, chunk: bytes) -> None:
        self.data.extend(chunk)
        if self.path is not None:
            with self.path.open("ab") as handle:
                handle.write(chunk)


def _reader(pipe, capture: _Capture) -> None:
    try:
        while True:
            chunk = pipe.read(65536)
            if not chunk:
                break
            capture.write(chunk)
    finally:
        pipe.close()


def _run_powershell(
    code: str,
    cwd: str | None = None,
    timeout_seconds: float | None = None,
    output_directory: str | None = None,
    unbounded: bool = False,
) -> dict:
    started = time.monotonic()
    started_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    invocation_id = uuid.uuid4().hex
    requested_timeout = timeout_seconds
    if unbounded:
        effective_timeout = None
    elif timeout_seconds is None:
        effective_timeout = DEFAULT_TIMEOUT_SECONDS
    else:
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive unless unbounded is true")
        effective_timeout = float(timeout_seconds)

    workdir = _SERVER_CWD if cwd is None else Path(cwd)
    if not workdir.is_dir():
        return {
            "schema": RESULT_SCHEMA,
            "id": invocation_id,
            "outcome": "failed-to-launch",
            "success": False,
            "native_exit_code": None,
            "stdout": "",
            "stderr": f"cwd is not a directory: {workdir}",
            "timeout_seconds_requested": requested_timeout,
            "timeout_seconds_effective": effective_timeout,
            "cleanup": "not-needed",
        }

    output_root: Path | None = None
    if output_directory:
        output_root = Path(output_directory)
        if output_root.exists():
            return {
                "schema": RESULT_SCHEMA,
                "id": invocation_id,
                "outcome": "failed-to-launch",
                "success": False,
                "native_exit_code": None,
                "stdout": "",
                "stderr": f"output_directory already exists: {output_root}",
                "timeout_seconds_requested": requested_timeout,
                "timeout_seconds_effective": effective_timeout,
                "cleanup": "not-needed",
            }
        output_root.mkdir(parents=True)

    powershell_executable = _resolve_powershell_executable()
    if not Path(powershell_executable).is_file():
        return {
            "schema": RESULT_SCHEMA,
            "id": invocation_id,
            "outcome": "failed-to-launch",
            "success": False,
            "native_exit_code": None,
            "stdout": "",
            "stderr": f"PowerShell executable not found: {powershell_executable}",
            "timeout_seconds_requested": requested_timeout,
            "timeout_seconds_effective": effective_timeout,
            "cleanup": "not-needed",
        }

    version, framework = _probe_powershell(powershell_executable)
    parsed = _parse_ps_version(version)
    if parsed < MINIMUM_PS_VERSION:
        return {
            "schema": RESULT_SCHEMA,
            "id": invocation_id,
            "outcome": "failed-to-launch",
            "success": False,
            "native_exit_code": None,
            "stdout": "",
            "stderr": f"PowerShell {version} is below required {MINIMUM_PS_VERSION[0]}.{MINIMUM_PS_VERSION[1]}",
            "powershell": {"executable": powershell_executable, "version": version, "dotnet": framework},
            "timeout_seconds_requested": requested_timeout,
            "timeout_seconds_effective": effective_timeout,
            "cleanup": "not-needed",
        }

    powershell_profile = _resolve_powershell_profile()
    powershell_code = _build_powershell_code(code)
    child_env = os.environ.copy()
    if powershell_profile:
        child_env[POWERSHELL_PROFILE_ENV_VAR] = powershell_profile
    else:
        child_env.pop(POWERSHELL_PROFILE_ENV_VAR, None)

    stdout_path = output_root / "stdout.txt" if output_root else None
    stderr_path = output_root / "stderr.txt" if output_root else None
    stdout_cap = _Capture(bytearray(), stdout_path)
    stderr_cap = _Capture(bytearray(), stderr_path)
    if stdout_path:
        stdout_path.write_bytes(b"")
    if stderr_path:
        stderr_path.write_bytes(b"")

    job = None
    process = subprocess.Popen(
        [powershell_executable, "-NoProfile", "-Command", powershell_code],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=str(workdir),
        env=child_env,
    )
    cleanup = "incomplete"
    outcome = "exited"
    try:
        if os.name == "nt":
            try:
                job = _WinJob()
                job.assign(process.pid)
            except OSError:
                job = None
        stdout_thread = threading.Thread(target=_reader, args=(process.stdout, stdout_cap), daemon=True)
        stderr_thread = threading.Thread(target=_reader, args=(process.stderr, stderr_cap), daemon=True)
        stdout_thread.start()
        stderr_thread.start()
        try:
            process.wait(timeout=effective_timeout)
        except subprocess.TimeoutExpired:
            outcome = "timed-out"
            _kill_tree(process)
            try:
                process.wait(timeout=DEFAULT_CLEANUP_SECONDS)
            except subprocess.TimeoutExpired:
                cleanup = "incomplete"
            else:
                cleanup = "complete"
        else:
            cleanup = "complete"
        stdout_thread.join(timeout=DEFAULT_CLEANUP_SECONDS)
        stderr_thread.join(timeout=DEFAULT_CLEANUP_SECONDS)
        if stdout_thread.is_alive() or stderr_thread.is_alive():
            cleanup = "incomplete"
    finally:
        if job is not None:
            job.close()

    stdout_bytes, stdout_trunc = _trim_bytes(bytes(stdout_cap.data))
    stderr_bytes, stderr_trunc = _trim_bytes(bytes(stderr_cap.data))
    stdout_text, stdout_decode = _decode(stdout_bytes)
    stderr_text, stderr_decode = _decode(stderr_bytes)
    elapsed_ms = round((time.monotonic() - started) * 1000, 2)
    exit_code = process.poll()
    success = outcome == "exited" and exit_code == 0 and cleanup == "complete"
    result = {
        "schema": RESULT_SCHEMA,
        "id": invocation_id,
        "outcome": outcome,
        "success": success,
        "native_exit_code": exit_code,
        "stdout": stdout_text,
        "stderr": stderr_text,
        "capture": {
            "stdout_bytes": len(stdout_cap.data),
            "stderr_bytes": len(stderr_cap.data),
            "stdout_truncated": stdout_trunc,
            "stderr_truncated": stderr_trunc,
            "stdout_decode_replaced": stdout_decode,
            "stderr_decode_replaced": stderr_decode,
            "stdout_path": str(stdout_path) if stdout_path else None,
            "stderr_path": str(stderr_path) if stderr_path else None,
        },
        "timeout_seconds_requested": requested_timeout,
        "timeout_seconds_effective": effective_timeout,
        "cleanup": cleanup,
        "timing_ms": {"elapsed": elapsed_ms},
        "powershell": {
            "executable": powershell_executable,
            "version": version,
            "dotnet": framework,
            "profile": powershell_profile,
        },
        "cwd": str(workdir),
        "started_utc": started_utc,
    }
    if output_root is not None:
        (output_root / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


@mcp.tool()
def run_powershell(
    code: str,
    cwd: str | None = None,
    timeout_seconds: float | None = None,
    output_directory: str | None = None,
    unbounded: bool = False,
) -> dict:
    """Run PowerShell in a fresh process and return stdout, stderr, exit status and limits."""
    return _run_powershell(
        code,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        output_directory=output_directory,
        unbounded=unbounded,
    )


if __name__ == "__main__":
    mcp.run()
