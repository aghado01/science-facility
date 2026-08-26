"""
spcx_viz (package: mvp) — Notebook-side helpers for inspecting spcx runs.

Quick start::

    from mvp.bootstrap import setup
    from spcx_viz import display_run, compare_runs, eval_table, plot_sweep

    ws  = setup()                                  # adds notebook/ to sys.path,
                                                   # adds Spcx.exe to PATH,
                                                   # returns a Workspace
    spc = ws.run_spc(["--config", "presets/spc-blatt-canonical.json"])
    hdb = ws.run_hdbscan(["--dataset", "BlattHierarchy", "--min-pts", "5"])

    display_run(spc)
    compare_runs(spc, hdb)
    eval_table([spc, hdb], ["SPC", "HDBSCAN"])
    plot_sweep(spc)

Layout:

* :mod:`mvp.bootstrap` — :func:`setup` (one-call session wiring)
* :mod:`mvp.workspace` — :class:`Workspace` (notebook-facing entry point)
* :mod:`mvp.cli`       — CLI invocation + repo discovery
* :mod:`mvp.runs`      — run-dir discovery + manifest / graph-health loading
* :mod:`mvp.loader`    — :class:`RunResult` + CSV/JSON loaders
* :mod:`mvp.display`   — high-level plot helpers
* :mod:`mvp.scatter`   — matplotlib 2-D primitives
* :mod:`mvp.scatter3d` — plotly 3-D primitives
* :mod:`mvp.palette`   — colour palettes
"""

from .bootstrap import setup, setup_notebook_session
from .datasets  import (
    SpcNDataset, SpcNModel,
    load_spc_n_data, load_spc_n_model,
    embed_via_mds, save_features_csv, load_spc_n_example,
)
from .cli       import (
    repo_root, find_spcx_cli,
    run_spcx, run_spc, run_hdbscan, run_extract, run_graph_health,
)
from .display   import (
    display_run, compare_runs, eval_table,
    plot_sweep, sweep_at_T, plot_2x2_self,
)
from .loader    import RunResult, load, load_spc, load_hdbscan
from .palette   import get_palette, label_colors
from .progress  import stream_subprocess
from .runs      import latest_run_dir, list_run_dirs, load_manifest, load_graph_health
from .scatter   import scatter2d, plot_2x2, plot_nx2, axis_pair_grid
from .scatter3d import scatter3d, compare3d, membership_3d
from .workspace import Workspace

__all__ = [
    # Notebook bootstrap (one-call session wiring)
    "setup", "setup_notebook_session",
    # Primary entry point
    "Workspace",
    # Loading
    "RunResult", "load", "load_spc", "load_hdbscan",
    # Display
    "display_run", "compare_runs", "eval_table",
    "plot_sweep", "sweep_at_T", "plot_2x2_self",
    # Scatter primitives
    "scatter2d", "plot_2x2", "plot_nx2", "axis_pair_grid",
    "scatter3d", "compare3d", "membership_3d",
    # Palettes
    "get_palette", "label_colors",
    # Discovery
    "latest_run_dir", "list_run_dirs", "load_manifest", "load_graph_health",
    # CLI invocation
    "repo_root", "find_spcx_cli",
    "run_spcx", "run_spc", "run_hdbscan", "run_extract", "run_graph_health",
    # Progress streaming
    "stream_subprocess",
    # External dataset importers
    "SpcNDataset", "SpcNModel",
    "load_spc_n_data", "load_spc_n_model",
    "embed_via_mds", "save_features_csv", "load_spc_n_example",
]
# NOTE: the headless benchmark entry point is the `mvp.bench` module
# (invoked as `python -m mvp.bench`), intentionally NOT re-exported
# here to avoid the runpy double-import warning when the module is run
# as __main__.
