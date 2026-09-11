"""Bounded PowerShell invocation: one child, both streams, cleanup of that tree."""

from __future__ import annotations

import base64
import codecs
import json
import math
import os
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from windows_job import (
    CREATE_NO_WINDOW,
    CREATE_SUSPENDED,
    WindowsJob,
    pid_is_running,
    resume_process,
)


RESULT_SCHEMA = "pwsh_exec/invocation/0.1"
MINIMUM_PS_VERSION = (7, 5)
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_CLEANUP_SECONDS = 30.0
COMBINED_MEMORY_LIMIT = 2 * 1024 * 1024
PROFILE_ENV_VAR = "MCP_POWERSHELL_PROFILE"
_VERSION_CACHE: dict[str, tuple[str, str]] = {}
_VERSION_LOCK = threading.Lock()
_IN_FLIGHT: dict[str, "_OwnedInvocation"] = {}
_IN_FLIGHT_LOCK = threading.Lock()


def build_powershell_script(code: str) -> str:
    return (
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
        "$OutputEncoding = [Console]::OutputEncoding; "
        f"if ($env:{PROFILE_ENV_VAR} -and $env:{PROFILE_ENV_VAR}.Trim()) {{ "
        f"$__mcpPowerShellProfile = (Resolve-Path -LiteralPath $env:{PROFILE_ENV_VAR} -ErrorAction Stop).ProviderPath; "
        "$null = . $__mcpPowerShellProfile; "
        "Remove-Variable __mcpPowerShellProfile -ErrorAction SilentlyContinue; "
        "}; "
        f"{code}"
    )


def encoded_command(script: str) -> str:
    return base64.b64encode(script.encode("utf-16le")).decode("ascii")


def parse_ps_version(text: str) -> tuple[int, ...]:
    parts: list[int] = []
    for item in (text or "").split("."):
        digits = "".join(ch for ch in item if ch.isdigit())
        if digits:
            parts.append(int(digits))
    return tuple(parts or [0])


def meets_runtime_floor(parsed: tuple[int, ...]) -> bool:
    major = parsed[0] if parsed else 0
    minor = parsed[1] if len(parsed) > 1 else 0
    return (major, minor) >= MINIMUM_PS_VERSION


def probe_powershell(executable: str) -> tuple[str, str]:
    resolved = str(Path(executable).resolve()) if Path(executable).is_file() else executable
    with _VERSION_LOCK:
        cached = _VERSION_CACHE.get(resolved)
        if cached:
            return cached
    script = (
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
        "$OutputEncoding = [Console]::OutputEncoding; "
        "Write-Output $PSVersionTable.PSVersion.ToString(); "
        "try { Write-Output ([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription) } "
        "catch { Write-Output '' }"
    )
    probe = subprocess.run(
        [executable, "-NoProfile", "-EncodedCommand", encoded_command(script)],
        capture_output=True,
        timeout=15,
        check=False,
    )
    stdout, _ = _decode(probe.stdout or b"")
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    version = lines[0] if lines else ""
    framework = lines[1] if len(lines) > 1 else ""
    if probe.returncode != 0 and not version:
        stderr, _ = _decode(probe.stderr or b"")
        raise RuntimeError(
            f"PowerShell version probe failed (exit {probe.returncode}): {stderr or stdout}"
        )
    with _VERSION_LOCK:
        _VERSION_CACHE[resolved] = (version, framework)
    return version, framework


def _decode(data: bytes) -> tuple[str, bool]:
    try:
        return data.decode("utf-8"), False
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace"), True


def _utf8_cut(data: bytes, limit: int, from_end: bool = False) -> bytes:
    if limit <= 0:
        return b""
    cut = data[-limit:] if from_end else data[:limit]
    if not from_end:
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        decoder.decode(cut, final=False)
        pending, _ = decoder.getstate()
        return cut[:-len(pending)] if pending else cut
    while cut and (cut[0] & 0xC0) == 0x80:
        cut = cut[1:]
    return cut


class StreamCapture:
    def __init__(self, limit: int, path: Path | None) -> None:
        self.limit = max(limit, 0)
        self.head_limit = self.limit // 2
        self.tail_limit = self.limit - self.head_limit
        self.head = bytearray()
        self.tail = bytearray()
        self.observed = 0
        self.truncated = False
        self.failure: str | None = None
        self.path = path
        self._file = path.open("wb") if path is not None else None
        self._lock = threading.Lock()

    def write(self, chunk: bytes) -> None:
        if not chunk:
            return
        with self._lock:
            self.observed += len(chunk)
            self.truncated = self.observed > self.limit
            durable_chunk = chunk
            if self.head_limit > 0 and len(self.head) < self.head_limit:
                take = min(len(chunk), self.head_limit - len(self.head))
                self.head.extend(chunk[:take])
                chunk = chunk[take:]
            if self.tail_limit > 0:
                self.tail.extend(chunk)
                if len(self.tail) > self.tail_limit:
                    overflow = len(self.tail) - self.tail_limit
                    del self.tail[:overflow]
        # Disk I/O must not hold the snapshot lock when the caller's cleanup expires.
        if self._file is not None:
            self._file.write(durable_chunk)
            self._file.flush()

    def close(self) -> None:
        with self._lock:
            if self._file is not None:
                self._file.close()
                self._file = None

    def retained(self) -> bytes:
        with self._lock:
            if not self.truncated:
                return bytes(self.head + self.tail)
            head = _utf8_cut(bytes(self.head), len(self.head))
            tail = _utf8_cut(bytes(self.tail), len(self.tail), from_end=True)
            return head + tail

    def display(self) -> tuple[bytes, bool]:
        with self._lock:
            if not self.truncated:
                return bytes(self.head + self.tail), False
            head = _utf8_cut(bytes(self.head), len(self.head))
            tail = _utf8_cut(bytes(self.tail), len(self.tail), from_end=True)
            return head + b"\n...<truncated>...\n" + tail, True


def _reader(pipe, capture: StreamCapture) -> None:
    try:
        while True:
            chunk = pipe.read(65536)
            if not chunk:
                break
            capture.write(chunk)
    except Exception as exc:
        capture.failure = str(exc)
    finally:
        try:
            pipe.close()
        except Exception:
            pass
        try:
            capture.close()
        except Exception as exc:
            capture.failure = str(exc)


@dataclass
class _OwnedInvocation:
    invocation_id: str
    process: subprocess.Popen[bytes] | None = None
    job: WindowsJob | None = None
    cancel_event: threading.Event = field(default_factory=threading.Event)
    finished: threading.Event = field(default_factory=threading.Event)

    def request_stop(self) -> None:
        self.cancel_event.set()


def _release_when_finished(owned: _OwnedInvocation, readers: tuple) -> None:
    """Retain and reap an invocation whose bounded foreground cleanup was incomplete."""
    if owned.process is not None:
        owned.process.wait()
    for reader in readers:
        if reader is not None:
            reader.join()
    with _IN_FLIGHT_LOCK:
        _IN_FLIGHT.pop(owned.invocation_id, None)
    owned.finished.set()


def shutdown_in_flight(timeout_seconds: float = DEFAULT_CLEANUP_SECONDS) -> None:
    with _IN_FLIGHT_LOCK:
        owned = list(_IN_FLIGHT.values())
    deadline = time.monotonic() + max(timeout_seconds, 0)
    for item in owned:
        item.request_stop()
        _stop_tree(item.process, item.job)
    for item in owned:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        item.finished.wait(timeout=remaining)


def _stop_tree(process: subprocess.Popen[bytes] | None, job: WindowsJob | None) -> list[str]:
    diagnostics: list[str] = []
    if process is None:
        return diagnostics
    if process.poll() is not None and job is None:
        return diagnostics
    if job is not None:
        try:
            job.terminate(1)
        except Exception as exc:
            diagnostics.append(f"TerminateJobObject failed: {exc}")
        if process.poll() is None:
            try:
                process.kill()
            except Exception as exc:
                diagnostics.append(f"process.kill failed: {exc}")
        return diagnostics
    if process.poll() is None:
        try:
            process.kill()
        except Exception as exc:
            diagnostics.append(f"process.kill failed: {exc}")
        if sys.platform == "win32":
            try:
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=5,
                )
            except Exception as exc:
                diagnostics.append(f"taskkill failed: {exc}")
        elif process.poll() is None:
            try:
                os.killpg(process.pid, 9)
            except Exception as exc:
                diagnostics.append(f"killpg failed: {exc}")
    return diagnostics


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cleanup_record(
    status: str,
    *,
    job_object: str = "not-needed",
    kill_on_job_close: bool = False,
    diagnostics: list[str] | None = None,
) -> dict:
    return {
        "status": status,
        "job_object": job_object,
        "kill_on_job_close": kill_on_job_close,
        "diagnostics": list(diagnostics or []),
    }


def _result(
    *,
    invocation_id: str,
    outcome: str,
    success: bool,
    native_exit_code: int | None,
    stdout: str,
    stderr: str,
    capture: dict,
    timeout_requested: float | None,
    timeout_effective: float | None,
    cleanup: dict,
    timing_ms: dict,
    powershell: dict | None,
    cwd: str | None,
    started_utc: str,
) -> dict:
    return {
        "schema": RESULT_SCHEMA,
        "id": invocation_id,
        "outcome": outcome,
        "success": success,
        "native_exit_code": native_exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "capture": capture,
        "timeout_seconds_requested": timeout_requested,
        "timeout_seconds_effective": timeout_effective,
        "cleanup": cleanup,
        "timing_ms": timing_ms,
        "powershell": powershell,
        "cwd": cwd,
        "started_utc": started_utc,
    }


def _empty_capture() -> dict:
    return {
        "stdout_bytes_observed": 0,
        "stderr_bytes_observed": 0,
        "stdout_bytes_retained": 0,
        "stderr_bytes_retained": 0,
        "stdout_truncated": False,
        "stderr_truncated": False,
        "stdout_decode_replaced": False,
        "stderr_decode_replaced": False,
        "stdout_path": None,
        "stderr_path": None,
        "result_path": None,
    }


def _finalize_streams(
    stdout_cap: StreamCapture | None,
    stderr_cap: StreamCapture | None,
    output_root: Path | None,
) -> tuple[str, str, dict]:
    if stdout_cap is None:
        stdout_cap = StreamCapture(0, None)
    if stderr_cap is None:
        stderr_cap = StreamCapture(0, None)
    stdout_bytes, stdout_trunc = stdout_cap.display()
    stderr_bytes, stderr_trunc = stderr_cap.display()
    stdout_text, stdout_lossy = _decode(stdout_bytes)
    stderr_text, stderr_lossy = _decode(stderr_bytes)
    result_path = str(output_root / "result.json") if output_root is not None else None
    capture = {
        "stdout_bytes_observed": stdout_cap.observed,
        "stderr_bytes_observed": stderr_cap.observed,
        "stdout_bytes_retained": len(stdout_cap.retained()),
        "stderr_bytes_retained": len(stderr_cap.retained()),
        "stdout_truncated": stdout_trunc,
        "stderr_truncated": stderr_trunc,
        "stdout_decode_replaced": stdout_lossy,
        "stderr_decode_replaced": stderr_lossy,
        "stdout_path": str(stdout_cap.path) if stdout_cap.path else None,
        "stderr_path": str(stderr_cap.path) if stderr_cap.path else None,
        "result_path": result_path,
    }
    return stdout_text, stderr_text, capture


def _write_result_file(output_root: Path | None, result: dict) -> None:
    if output_root is None or not output_root.is_dir():
        return
    path = output_root / "result.json"
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def run(
    code: str,
    *,
    executable: str,
    profile: str | None,
    cwd: Path,
    timeout_seconds: float | None,
    unbounded: bool,
    output_directory: str | None,
    mcp_root: Path,
    cancel_event: threading.Event | None = None,
    cleanup_seconds: float = DEFAULT_CLEANUP_SECONDS,
    memory_limit: int = COMBINED_MEMORY_LIMIT,
    kill_tree=None,
) -> dict:
    started = time.monotonic()
    started_utc = _now_utc()
    invocation_id = uuid.uuid4().hex
    cancel_event = cancel_event or threading.Event()
    requested_timeout = timeout_seconds
    powershell_info: dict | None = None
    stdout_cap: StreamCapture | None = None
    stderr_cap: StreamCapture | None = None
    output_root: Path | None = None
    owned = _OwnedInvocation(invocation_id=invocation_id, cancel_event=cancel_event)
    timing: dict[str, float] = {}
    effective_timeout: float | None = None

    def elapsed() -> float:
        return round((time.monotonic() - started) * 1000, 2)

    def fail_launch(message: str, *, extra_stderr: str = "", outcome: str = "failed-to-launch") -> dict:
        stderr = message if not extra_stderr else f"{message}\n{extra_stderr}"
        capture = _empty_capture()
        if output_root is not None:
            capture["result_path"] = str(output_root / "result.json")
        result = _result(
            invocation_id=invocation_id,
            outcome=outcome,
            success=False,
            native_exit_code=None,
            stdout="",
            stderr=stderr,
            capture=capture,
            timeout_requested=requested_timeout,
            timeout_effective=effective_timeout,
            cleanup=_cleanup_record("not-needed"),
            timing_ms={"elapsed": elapsed(), **timing},
            powershell=powershell_info,
            cwd=str(cwd) if cwd else None,
            started_utc=started_utc,
        )
        _write_result_file(output_root, result)
        return result

    validation_start = time.monotonic()
    if unbounded:
        effective_timeout: float | None = None
    else:
        if timeout_seconds is None:
            effective_timeout = DEFAULT_TIMEOUT_SECONDS
        else:
            try:
                effective_timeout = float(timeout_seconds)
            except (TypeError, ValueError):
                timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
                return fail_launch("timeout_seconds must be a number")
            if not math.isfinite(effective_timeout) or effective_timeout <= 0:
                timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
                return fail_launch(
                    "timeout_seconds must be finite and > 0 unless unbounded is true"
                )

    if not cwd.is_dir():
        timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
        return fail_launch(f"cwd is not a directory: {cwd}")

    if output_directory:
        candidate_root = Path(output_directory).resolve()
        if candidate_root.exists():
            timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
            return fail_launch(f"output_directory already exists: {candidate_root}")
        if _is_under(candidate_root, mcp_root):
            timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
            return fail_launch(
                f"output_directory must not be under {mcp_root}: {candidate_root}"
            )
        try:
            candidate_root.mkdir(parents=True, exist_ok=False)
        except FileExistsError:
            timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
            return fail_launch(f"output_directory already exists: {candidate_root}")
        except OSError as exc:
            timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
            return fail_launch(f"output_directory could not be created: {exc}")
        # Only a successful exclusive create grants ownership of result.json.
        output_root = candidate_root

    executable_path = Path(executable)
    if not executable_path.is_file():
        timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
        return fail_launch(f"PowerShell executable not found: {executable}")

    try:
        version, framework = probe_powershell(str(executable_path))
    except Exception as exc:
        timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
        return fail_launch(f"PowerShell version probe failed: {exc}")

    powershell_info = {
        "executable": str(executable_path.resolve()),
        "version": version,
        "dotnet": framework,
        "profile": profile,
    }
    if not meets_runtime_floor(parse_ps_version(version)):
        timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
        return fail_launch(
            f"PowerShell {version or '(unknown)'} is below required "
            f"{MINIMUM_PS_VERSION[0]}.{MINIMUM_PS_VERSION[1]}"
        )

    if profile is not None and not Path(profile).is_file():
        timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)
        return fail_launch(f"PowerShell profile not found: {profile}")

    timing["validation"] = round((time.monotonic() - validation_start) * 1000, 2)

    if cancel_event.is_set():
        return fail_launch("invocation cancelled before launch", outcome="cancelled")

    per_stream = max(memory_limit // 2, 1)
    stdout_path = output_root / "stdout.bin" if output_root is not None else None
    stderr_path = output_root / "stderr.bin" if output_root is not None else None
    try:
        stdout_cap = StreamCapture(per_stream, stdout_path)
        stderr_cap = StreamCapture(per_stream, stderr_path)
    except OSError as exc:
        if stdout_cap is not None:
            stdout_cap.close()
        return fail_launch(f"could not open invocation streams: {exc}")

    child_env = os.environ.copy()
    if profile:
        child_env[PROFILE_ENV_VAR] = profile
    else:
        child_env.pop(PROFILE_ENV_VAR, None)

    script = build_powershell_script(code)
    argv = [
        str(executable_path),
        "-NoProfile",
        "-EncodedCommand",
        encoded_command(script),
    ]
    popen_kwargs: dict = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "cwd": str(cwd),
        "env": child_env,
        "bufsize": 0,
    }
    creationflags = 0
    if sys.platform == "win32":
        creationflags = CREATE_NO_WINDOW | CREATE_SUSPENDED
        popen_kwargs["creationflags"] = creationflags
    else:
        popen_kwargs["start_new_session"] = True

    launch_start = time.monotonic()
    job: WindowsJob | None = None
    job_status = "unsupported" if sys.platform != "win32" else "assign-failed"
    kill_on_close = False
    diagnostics: list[str] = []
    outcome = "exited"
    process: subprocess.Popen[bytes] | None = None
    stdout_thread = stderr_thread = None

    try:
        process = subprocess.Popen(argv, **popen_kwargs)
    except OSError as exc:
        stdout_cap.close()
        stderr_cap.close()
        timing["launch"] = round((time.monotonic() - launch_start) * 1000, 2)
        return fail_launch(f"failed to spawn PowerShell: {exc}")

    owned.process = process
    resumed = False
    try:
        if sys.platform == "win32":
            try:
                job = WindowsJob()
                job.assign(int(process.pid))
                job_status = "assigned"
                kill_on_close = job.kill_on_close
            except Exception as exc:
                job_status = "assign-failed"
                diagnostics.append(f"Job Object not assigned: {exc}")
            try:
                if job_status != "assigned":
                    raise RuntimeError("PowerShell containment could not be established")
                resume_process(process)
                resumed = True
            except Exception as exc:
                diagnostics.append(f"resume failed: {exc}")
                _stop_tree(process, job)
                try:
                    process.wait(timeout=cleanup_seconds)
                except subprocess.TimeoutExpired:
                    pass
                timing["launch"] = round((time.monotonic() - launch_start) * 1000, 2)
                stdout_text, stderr_text, capture = _finalize_streams(
                    stdout_cap, stderr_cap, output_root
                )
                result = _result(
                    invocation_id=invocation_id,
                    outcome="failed-to-launch",
                    success=False,
                    native_exit_code=process.poll(),
                    stdout=stdout_text,
                    stderr=(stderr_text + f"\nfailed to resume PowerShell: {exc}").strip(),
                    capture=capture,
                    timeout_requested=requested_timeout,
                    timeout_effective=effective_timeout,
                    cleanup=_cleanup_record(
                        "complete" if process.poll() is not None else "incomplete",
                        job_object=job_status,
                        kill_on_job_close=kill_on_close,
                        diagnostics=diagnostics,
                    ),
                    timing_ms={"elapsed": elapsed(), **timing},
                    powershell=powershell_info,
                    cwd=str(cwd),
                    started_utc=started_utc,
                )
                _write_result_file(output_root, result)
                return result
        else:
            job_status = "unsupported"
            resumed = True

        owned.job = job
        with _IN_FLIGHT_LOCK:
            _IN_FLIGHT[invocation_id] = owned

        assert process.stdout is not None
        assert process.stderr is not None
        stdout_thread = threading.Thread(
            target=_reader, args=(process.stdout, stdout_cap), daemon=True
        )
        stderr_thread = threading.Thread(
            target=_reader, args=(process.stderr, stderr_cap), daemon=True
        )
        stdout_thread.start()
        stderr_thread.start()
        timing["launch"] = round((time.monotonic() - launch_start) * 1000, 2)

        deadline = None if effective_timeout is None else started + effective_timeout
        wait_slice = 0.05
        while True:
            if cancel_event.is_set():
                outcome = "cancelled"
                break
            code_now = process.poll()
            if code_now is not None:
                outcome = "exited"
                break
            if deadline is not None and time.monotonic() >= deadline:
                outcome = "timed-out"
                break
            timeout = wait_slice
            if deadline is not None:
                timeout = min(wait_slice, max(deadline - time.monotonic(), 0))
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                continue

        cleanup_start = time.monotonic()
        cleanup_deadline = cleanup_start + max(cleanup_seconds, 0)
        remaining = lambda: max(cleanup_deadline - time.monotonic(), 0)
        cleanup_status = "complete"
        stop_fn = kill_tree or _stop_tree
        if outcome in {"timed-out", "cancelled"}:
            diagnostics.extend(stop_fn(process, job))
        # Root exit is not tree completion. Stop descendants before waiting for EOF.
        elif job is not None and job.process_ids() != []:
            diagnostics.extend(stop_fn(process, job))
        try:
            process.wait(timeout=remaining())
        except subprocess.TimeoutExpired:
            cleanup_status = "incomplete"
            diagnostics.append("process still running after cleanup wait")
            diagnostics.extend(stop_fn(process, job))
        stdout_thread.join(timeout=remaining())
        stderr_thread.join(timeout=remaining())
        if stdout_thread.is_alive() or stderr_thread.is_alive():
            cleanup_status = "incomplete"
            diagnostics.append("stream reader did not finish within cleanup budget")
        for cap in (stdout_cap, stderr_cap):
            if cap.failure:
                cleanup_status = "incomplete"
                diagnostics.append(f"stream capture failed: {cap.failure}")

        leftover: list[int] | None = None
        if job is not None:
            leftover = job.process_ids()
            while leftover and remaining() > 0:
                time.sleep(min(0.02, remaining()))
                leftover = job.process_ids()
            if leftover != []:
                cleanup_status = "incomplete"
                diagnostics.append(f"job release not confirmed: {leftover}")

        if process.poll() is None:
            cleanup_status = "incomplete"

        timing["cleanup"] = round((time.monotonic() - cleanup_start) * 1000, 2)
        stdout_text, stderr_text, capture = _finalize_streams(
            stdout_cap, stderr_cap, output_root
        )
        native = process.poll()
        success = (
            outcome == "exited"
            and native == 0
            and cleanup_status == "complete"
        )
        result = _result(
            invocation_id=invocation_id,
            outcome=outcome,
            success=success,
            native_exit_code=native,
            stdout=stdout_text,
            stderr=stderr_text,
            capture=capture,
            timeout_requested=requested_timeout,
            timeout_effective=effective_timeout,
            cleanup=_cleanup_record(
                cleanup_status,
                job_object=job_status,
                kill_on_job_close=kill_on_close,
                diagnostics=diagnostics,
            ),
            timing_ms={"elapsed": elapsed(), **timing},
            powershell=powershell_info,
            cwd=str(cwd),
            started_utc=started_utc,
        )
        _write_result_file(output_root, result)
        return result
    finally:
        if not resumed and process is not None and process.poll() is None:
            _stop_tree(process, job)
        if job is not None:
            try:
                job.close()
            except Exception:
                pass
        readers = (stdout_thread, stderr_thread)
        if process.poll() is None or any(reader is not None and reader.is_alive() for reader in readers):
            with _IN_FLIGHT_LOCK:
                _IN_FLIGHT[invocation_id] = owned
            threading.Thread(target=_release_when_finished, args=(owned, readers), daemon=True).start()
        else:
            with _IN_FLIGHT_LOCK:
                _IN_FLIGHT.pop(invocation_id, None)
            owned.finished.set()
        # Reader threads own their stream handles, even after incomplete cleanup.
        # Before thread startup the launch owner must close them itself.
        for thread, pipe, cap in ((stdout_thread, process.stdout, stdout_cap),
                                  (stderr_thread, process.stderr, stderr_cap)):
            if thread is None:
                if pipe is not None:
                    pipe.close()
                if cap is not None:
                    cap.close()
