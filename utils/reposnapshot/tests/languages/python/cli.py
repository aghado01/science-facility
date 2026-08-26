"""
cli.py — Locate and invoke the published Spcx CLI.

The Spcx CLI is published as a self-contained win-x64 executable from
``projects/UserRepl/UserRepl.Publish.csproj``; this module assumes the
publish has already happened (no on-demand build). For session-wide
ergonomics (sys.path + PATH wiring), use :func:`mvp.bootstrap.setup`.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

__all__ = [
    "repo_root",
    "find_spcx_cli",
    "run_spcx",
    "run_spc",
    "run_hdbscan",
    "run_extract",
    "run_graph_health",
]


# ── Discovery ────────────────────────────────────────────────────────────────

def repo_root() -> Path:
    """Repo root — derived from this file's location (notebook/mvp/cli.py)."""
    return Path(__file__).resolve().parents[2]


def find_spcx_cli(root: Path | None = None) -> Path:
    """
    Locate the published Spcx executable. Looks at the two output
    layouts dotnet publish produces depending on flags; raises with a
    helpful message when neither is present.
    """
    root = Path(root or repo_root())
    # publish_base = root / "artifacts" / "bin" / "UserRepl.Publish" / "Release" / "net10.0" / "win-x64"
    fallback_base = root / "notebook" / "mvp" / "spcx"
    for candidate in (
        fallback_base / "Spcx.exe",
        # publish_base / "Spcx.exe",
        # publish_base / "publish" / "Spcx.exe",
    ):
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        f"Spcx.exe not found under {publish_base}. "
        "Publish the UserRepl.Publish project before running notebook cells."
    )


# ── Invocation ───────────────────────────────────────────────────────────────

def run_spcx(
    args: list[str],
    *,
    root: Path | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    """
    Run the Spcx CLI with the given args. Always invokes via the full
    discovered path so PATH state doesn't matter. ``check=True`` raises
    on non-zero exit.
    """
    root = Path(root or repo_root())
    cli = find_spcx_cli(root)
    proc = subprocess.run(
        [str(cli), *args],
        cwd=root,
        capture_output=capture,
        text=True,
    )
    if check:
        proc.check_returncode()
    return proc


def run_spc(args: list[str], **kw) -> subprocess.CompletedProcess[str]:
    return run_spcx(["spc", *args], **kw)


def run_hdbscan(args: list[str], **kw) -> subprocess.CompletedProcess[str]:
    return run_spcx(["hdbscan", *args], **kw)


def run_extract(run_dir: str | Path, *extra: str, **kw) -> subprocess.CompletedProcess[str]:
    return run_spcx(["extract", "--run-dir", str(run_dir), *extra], **kw)


def run_graph_health(run_dir: str | Path, *extra: str, **kw) -> subprocess.CompletedProcess[str]:
    return run_spcx(["graph-health", "--run-dir", str(run_dir), *extra], **kw)
