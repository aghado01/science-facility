"""Windows Job Object ownership for one MCP-started process tree."""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from typing import Any


JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
JobObjectExtendedLimitInformation = 9
JobObjectBasicProcessIdList = 3
PROCESS_SET_QUOTA = 0x0100
PROCESS_TERMINATE = 0x0001
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259
CREATE_SUSPENDED = 0x00000004
CREATE_NO_WINDOW = 0x08000000
TH32CS_SNAPTHREAD = 0x00000004
THREAD_SUSPEND_RESUME = 0x0002
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
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


class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ThreadID", wintypes.DWORD),
        ("th32OwnerProcessID", wintypes.DWORD),
        ("tpBasePri", ctypes.c_long),
        ("tpDeltaPri", ctypes.c_long),
        ("dwFlags", wintypes.DWORD),
    ]


def _kernel32() -> Any:
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    k32.SetInformationJobObject.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    k32.OpenThread.restype = wintypes.HANDLE
    k32.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.ResumeThread.argtypes = [wintypes.HANDLE]
    k32.Thread32First.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
    k32.Thread32Next.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
    return k32


class WindowsJob:
    """Owned Job Object with kill-on-job-close."""

    def __init__(self) -> None:
        if sys.platform != "win32":
            raise OSError("Job Objects are Windows-only")
        self._k32 = _kernel32()
        self._pyjob = None
        self._handle = None
        self._using_pywin32 = False
        self._create()

    def _create(self) -> None:
        try:
            import win32job

            job = win32job.CreateJobObject(None, "")
            info = win32job.QueryInformationJobObject(
                job, win32job.JobObjectExtendedLimitInformation
            )
            info["BasicLimitInformation"]["LimitFlags"] |= (
                win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            )
            win32job.SetInformationJobObject(
                job, win32job.JobObjectExtendedLimitInformation, info
            )
            self._pyjob = job
            self._using_pywin32 = True
            return
        except Exception:
            self._pyjob = None
            self._using_pywin32 = False

        handle = self._k32.CreateJobObjectW(None, None)
        if not handle:
            raise OSError("CreateJobObjectW failed")
        info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self._k32.SetInformationJobObject(
            handle,
            JobObjectExtendedLimitInformation,
            ctypes.byref(info),
            ctypes.sizeof(info),
        ):
            self._k32.CloseHandle(handle)
            raise OSError("SetInformationJobObject failed")
        self._handle = handle

    @property
    def kill_on_close(self) -> bool:
        return True

    def assign(self, pid: int) -> None:
        if self._using_pywin32:
            import win32api
            import win32con
            import win32job

            process_handle = win32api.OpenProcess(
                win32con.PROCESS_SET_QUOTA | win32con.PROCESS_TERMINATE, False, pid
            )
            try:
                win32job.AssignProcessToJobObject(self._pyjob, process_handle)
            finally:
                win32api.CloseHandle(process_handle)
            return

        handle = self._k32.OpenProcess(
            PROCESS_SET_QUOTA | PROCESS_TERMINATE, False, pid
        )
        if not handle:
            raise OSError("OpenProcess failed")
        try:
            if not self._k32.AssignProcessToJobObject(self._handle, handle):
                raise OSError("AssignProcessToJobObject failed")
        finally:
            self._k32.CloseHandle(handle)

    def terminate(self, exit_code: int = 1) -> None:
        if self._using_pywin32:
            import win32job

            win32job.TerminateJobObject(self._pyjob, exit_code)
            return
        if not self._k32.TerminateJobObject(self._handle, exit_code):
            raise OSError("TerminateJobObject failed")

    def process_ids(self) -> list[int] | None:
        if self._using_pywin32:
            try:
                import win32job

                info = win32job.QueryInformationJobObject(
                    self._pyjob, win32job.JobObjectBasicProcessIdList
                )
            except Exception:
                return None
            if isinstance(info, dict):
                pids = info.get("ProcessIdList") or info.get("process_id_list")
                if pids is None:
                    return []
                return [int(pid) for pid in pids]
            if isinstance(info, (list, tuple)):
                return [int(pid) for pid in info]
        return None

    def close(self) -> None:
        if self._using_pywin32 and self._pyjob is not None:
            try:
                import win32api

                win32api.CloseHandle(self._pyjob)
            except Exception:
                pass
            self._pyjob = None
            return
        if self._handle:
            self._k32.CloseHandle(self._handle)
            self._handle = None


def resume_process(process: Any) -> None:
    """Resume a CREATE_SUSPENDED child. Uses the Popen process handle, not a PID lookup."""
    if sys.platform != "win32":
        return
    handle = getattr(process, "_handle", None)
    if handle is None:
        raise OSError("process handle is missing")
    ntdll = ctypes.WinDLL("ntdll")
    status = ntdll.NtResumeProcess(ctypes.c_void_p(int(handle)))
    if status == 0:
        return
    _resume_threads(int(process.pid))


def _resume_threads(pid: int) -> None:
    k32 = _kernel32()
    snapshot = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    if snapshot in (0, INVALID_HANDLE_VALUE):
        raise OSError("CreateToolhelp32Snapshot failed")
    try:
        entry = THREADENTRY32()
        entry.dwSize = ctypes.sizeof(THREADENTRY32)
        Thread32First = k32.Thread32First
        Thread32Next = k32.Thread32Next
        Thread32First.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
        Thread32Next.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
        more = Thread32First(snapshot, ctypes.byref(entry))
        resumed = False
        while more:
            if entry.th32OwnerProcessID == pid:
                thread = k32.OpenThread(
                    THREAD_SUSPEND_RESUME, False, entry.th32ThreadID
                )
                if thread:
                    try:
                        k32.ResumeThread(thread)
                        resumed = True
                    finally:
                        k32.CloseHandle(thread)
            more = Thread32Next(snapshot, ctypes.byref(entry))
        if not resumed:
            raise OSError("no threads resumed")
    finally:
        k32.CloseHandle(snapshot)


def pid_is_running(pid: int) -> bool:
    if sys.platform != "win32" or pid <= 0:
        return False
    k32 = _kernel32()
    handle = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    try:
        code = wintypes.DWORD()
        if not k32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return int(code.value) == STILL_ACTIVE
    finally:
        k32.CloseHandle(handle)
