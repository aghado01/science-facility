"""Assign a child to a kill-on-close job, then abort without Python cleanup."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from windows_job import CREATE_NO_WINDOW, CREATE_SUSPENDED, WindowsJob, resume_process


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--executable", required=True)
    args = parser.parse_args()
    job = WindowsJob()
    process = subprocess.Popen(
        [args.executable, "-NoProfile", "-Command", "Start-Sleep -Seconds 60"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW | CREATE_SUSPENDED,
    )
    job.assign(int(process.pid))
    resume_process(process)
    Path(args.pid_file).write_text(str(process.pid), encoding="utf-8")
    os._exit(1)


if __name__ == "__main__":
    main()
