"""
bootstrap.py — One-call notebook session setup.

Idempotently wires up the things a fresh Jupyter / IPython session
needs to talk to the published Spcx CLI and the local helper package:

  * ``notebook/`` on :data:`sys.path` so ``import spcx_viz`` resolves
  * The published ``Spcx.exe`` directory prepended to ``PATH`` so
    bare ``Spcx.exe`` invocations work in shell cells (``!Spcx ...``)
  * Returns a :class:`Workspace` ready to use

Typical first cell::

    from mvp.bootstrap import setup
    ws = setup()
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from .cli       import find_spcx_cli, repo_root
from .workspace import Workspace

__all__ = ["setup", "setup_notebook_session"]


def setup(root: Path | str | None = None, *, verbose: bool = True) -> Workspace:
    """
    Bootstrap a notebook session and return a ready
    :class:`Workspace`. Idempotent — safe to call multiple times in
    the same kernel.
    """
    root_path = Path(root) if root is not None else repo_root()
    if not root_path.exists():
        raise FileNotFoundError(f"Repo root does not exist: {root_path}")

    # sys.path so `import spcx_viz` resolves from the notebook shim.
    notebook_dir = root_path / "notebook"
    sys_path_added = _ensure_on_sys_path(notebook_dir)

    # PATH so `!Spcx ...` cells and any subprocess that doesn't pass
    # a full path can still find the published binary.
    cli_path = find_spcx_cli(root_path)
    path_added = _ensure_on_path(cli_path.parent)

    if verbose:
        print(f"repo       : {root_path}")
        print(f"spcx_cli   : {cli_path.name} @ {cli_path.parent}")
        if sys_path_added: print(f"sys.path   : + {notebook_dir}")
        if path_added:     print(f"PATH       : + {cli_path.parent}")

    return Workspace.discover(root_path)


# Long-form alias for those who prefer the descriptive name.
setup_notebook_session = setup


# ── Idempotency helpers ─────────────────────────────────────────────────────

def _ensure_on_sys_path(dir_path: Path) -> bool:
    """Prepend ``dir_path`` to :data:`sys.path` if not already there."""
    s = str(dir_path)
    if s in sys.path:
        return False
    sys.path.insert(0, s)
    return True


def _ensure_on_path(dir_path: Path) -> bool:
    """Prepend ``dir_path`` to ``$PATH`` if not already there."""
    s = str(dir_path)
    current = os.environ.get("PATH", "")
    if s in current.split(os.pathsep):
        return False
    os.environ["PATH"] = s + (os.pathsep + current if current else "")
    return True
