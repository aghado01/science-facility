"""
bench.py — Headless benchmarking entry point.

Runs SPC + HDBSCAN against a dataset, writes the standard plot pack +
eval table to ``<out>/`` (figures + CSV + per-run artifact dirs). No
interactive display — everything lands on disk so the same command
works from CI, tmux, or a scripted sweep.

Invoke:

    python notebook/mvp/bench.py --dataset BlattHierarchy --out artifacts/bench/blatt

Defaults:

* Schedule: ``fixed-grid``, ``linspace:0.10,0.90,200``, 4 replicas
* Graph: KNN k=10, Euclidean, MST-repair on, Gaussian kernel with
  auto-bandwidth
* HDBSCAN: minPts=5, Euclidean
* Figures: SPC sweep observables, per-run pancake scatter (true vs
  predicted), SPC↔HDBSCAN 2×2, axis-pair grids, static 3D PNG (via
  matplotlib) + interactive 3D HTML (via plotly) when dim ≥ 3
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

__all__ = ["main", "build_parser", "render_pack", "save_scatter3d_static"]


# ── Entry point ──────────────────────────────────────────────────────────────

def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    # Local imports so `--help` doesn't pay the matplotlib / sklearn /
    # plotly import cost. Support both package and script execution.
    if __package__ is None:
        notebook_dir = Path(__file__).resolve().parents[1]
        if str(notebook_dir) not in sys.path:
            sys.path.insert(0, str(notebook_dir))
        from mvp.bootstrap import setup
        from mvp.display   import eval_table
        from mvp.workspace import Workspace
    else:
        from .bootstrap import setup
        from .display   import eval_table
        from .workspace import Workspace

    out_dir     = Path(args.out).resolve()
    run_root    = out_dir / datetime.now().strftime("%Y%m%d_%H%M%S")
    slug        = _dataset_slug(args)
    figures_dir = run_root / "figures"
    figures_dir.mkdir(parents=True, exist_ok=True)

    # Bootstrap puts Spcx.exe on PATH + adds notebook/ to sys.path, then
    # returns a default Workspace. We override its bases so this bench run's
    # artifacts nest under a single run-stamp root so the figure pack, eval
    # CSV, and both algorithm run outputs all live together.
    default_ws = setup(verbose=False)
    ws = Workspace(
        root     = default_ws.root,
        spc_base = run_root / "spc",
        hdb_base = run_root / "hdbscan",
    )

    print(f"bench root  : {run_root}")
    print(f"figures     : {figures_dir}")
    print(f"spc_base    : {ws.spc_base}")
    print(f"hdb_base    : {ws.hdb_base}")
    print()

    spc = ws.run_spc(_build_spc_args(args, ws), label="spc")
    spc_dir = _flatten_run_dir(ws.spc_base, spc)
    spc.run_dir = spc_dir

    hdb = None
    if not args.skip_hdbscan:
        hdb = ws.run_hdbscan(_build_hdbscan_args(args, ws), label="hdbscan")
        hdb_dir = _flatten_run_dir(ws.hdb_base, hdb)
        hdb.run_dir = hdb_dir

    print()
    render_pack(spc, hdb, figures_dir,
                include_3d   = not args.no_3d,
                dataset_name = slug)

    # Eval table → CSV + console
    runs = [spc] + ([hdb] if hdb else [])
    names = ["SPC"] + (["HDBSCAN"] if hdb else [])
    df = eval_table(runs, names)
    eval_path = run_root / "eval.csv"
    df.to_csv(eval_path)
    print()
    print(df.to_string())
    print(f"\neval table : {eval_path}")
    return 0


# ── Argv ─────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    if __package__ is None:
        notebook_dir = Path(__file__).resolve().parents[1]
        if str(notebook_dir) not in sys.path:
            sys.path.insert(0, str(notebook_dir))
        from mvp.cli_shared import add_config_args, add_dataset_args
    else:
        from .cli_shared import add_config_args, add_dataset_args

    p = argparse.ArgumentParser(
        prog        = "mvp.bench",
        description = "Headless SPC + HDBSCAN benchmark — runs both and "
                      "writes the standard plot pack + eval CSV to disk.",
        formatter_class = argparse.ArgumentDefaultsHelpFormatter,
    )

    # ── Output ─────────────────────────────────────────────────────────────
    p.add_argument("--out", required=True, help="Output root directory.")

    # ── Dataset / config ───────────────────────────────────────────────────
    add_dataset_args(p)
    add_config_args(p, include_hdbscan=True)
    p.set_defaults(dataset=None, label_column=None, seed=None)

    # ── SPC schedule ──────────────────────────────────────────────────────
    p.add_argument("--temperatures", default=None,
                   help="Fixed-grid spec passed to Spcx.")
    p.add_argument("--replicas",     type=int, default=None)
    p.add_argument("--burn-in",      type=int, default=None)
    p.add_argument("--measure-cycles", type=int, default=None)
    p.add_argument("--final-burn",   type=int, default=None)
    p.add_argument("--final-cycles", type=int, default=None)
    p.add_argument("--q",            type=int, default=None)

    # ── Graph ─────────────────────────────────────────────────────────────
    p.add_argument("--k", type=int, default=None)
    p.add_argument("--distance-metric", default=None)
    p.add_argument("--no-mst", action="store_true", default=None,
                   help="Skip --ensure-connected (default: on).")

    # ── HDBSCAN ───────────────────────────────────────────────────────────
    p.add_argument("--min-pts",     type=int, default=None)
    p.add_argument("--allow-single-cluster", action="store_true", default=None)
    p.add_argument("--no-allow-single-cluster", action="store_false",
                   dest="allow_single_cluster")
    p.add_argument("--skip-hdbscan", action="store_true")

    # ── Figures ───────────────────────────────────────────────────────────
    p.add_argument("--no-3d", action="store_true",
                   help="Skip 3D PNG + HTML artifacts (still produces 2D).")
    return p


def _build_spc_args(args: argparse.Namespace, ws) -> list[str]:
    """Translate parsed argparse into the Spcx CLI's argv shape."""
    spc_args: list[str] = []
    if args.spc_config:
        spc_args += ["--config", str(args.spc_config)]

    if args.dataset_file:
        spc_args += ["--dataset-file", args.dataset_file,
                     "--label-column", args.label_column or "label"]
    elif not args.spc_config:
        spc_args += ["--dataset", args.dataset or "BlattHierarchy"]

    spc_args.append("--no-guid")

    if args.spc_config:
        if args.temperatures is not None:
            spc_args += ["--temperatures", args.temperatures]
        if args.replicas is not None:
            spc_args += ["--replicas", str(args.replicas)]
        if args.burn_in is not None:
            spc_args += ["--burn-in", str(args.burn_in)]
        if args.measure_cycles is not None:
            spc_args += ["--measure-cycles", str(args.measure_cycles)]
        if args.final_burn is not None:
            spc_args += ["--final-burn", str(args.final_burn)]
        if args.final_cycles is not None:
            spc_args += ["--final-cycles", str(args.final_cycles)]
        if args.q is not None:
            spc_args += ["--q", str(args.q)]
        if args.seed is not None:
            spc_args += ["--seed", str(args.seed)]
        if args.k is not None:
            spc_args += ["--k", str(args.k)]
        if args.distance_metric is not None:
            spc_args += ["--distance-metric", args.distance_metric]
        if args.no_mst:
            spc_args.append("--no-mst")
    else:
        spc_args += [
            "--schedule",        "fixed-grid",
            "--temperatures",    args.temperatures or "linspace:0.10,0.90,200",
            "--replicas",        str(args.replicas or 4),
            "--burn-in",         str(args.burn_in or 200),
            "--measure-cycles",  str(args.measure_cycles or 1000),
            "--final-burn",      str(args.final_burn or 1000),
            "--final-cycles",    str(args.final_cycles or 5000),
            "--q",               str(args.q or 20),
            "--seed",            str(args.seed or 42),
            "--k",               str(args.k or 10),
            "--distance-metric", args.distance_metric or "euclidean",
        ]
        if not args.no_mst:
            spc_args.append("--ensure-connected")

    spc_args += [
        "--base-dir",        str(ws.spc_base),
        "--run-name",        f"bench-{_dataset_slug(args)}",
    ]
    return spc_args


def _build_hdbscan_args(args: argparse.Namespace, ws) -> list[str]:
    hdb_args: list[str] = []
    if args.hdbscan_config:
        hdb_args += ["--config", str(args.hdbscan_config)]

    if args.dataset_file:
        hdb_args += ["--dataset-file", args.dataset_file,
                     "--label-column", args.label_column or "label"]
    elif not args.hdbscan_config:
        hdb_args += ["--dataset", args.dataset or "BlattHierarchy"]

    hdb_args.append("--no-guid")

    if args.hdbscan_config:
        if args.min_pts is not None:
            hdb_args += ["--min-pts", str(args.min_pts)]
        if args.allow_single_cluster is True:
            hdb_args.append("--allow-single-cluster")
        if args.distance_metric is not None:
            hdb_args += ["--distance-metric", args.distance_metric]
        if args.seed is not None:
            hdb_args += ["--seed", str(args.seed)]
    else:
        hdb_args += [
            "--min-pts",         str(args.min_pts or 5),
            "--allow-single-cluster",
            "--distance-metric", args.distance_metric or "euclidean",
            "--seed",            str(args.seed or 42),
        ]

    hdb_args += [
        "--base-dir",        str(ws.hdb_base),
        "--run-name",        f"bench-{_dataset_slug(args)}",
    ]
    return hdb_args


def _dataset_slug(args: argparse.Namespace) -> str:
    if args.dataset_file:
        return Path(args.dataset_file).stem.lower()
    if args.spc_config:
        slug = Path(args.spc_config).stem.lower()
        for prefix in ("spc-", "hdbscan-"):
            if slug.startswith(prefix):
                slug = slug[len(prefix):]
                break
        return slug.replace("-", "_")
    if args.dataset:
        return args.dataset.lower()
    return "bench"


def _flatten_run_dir(parent_dir: Path, result) -> Path:
    """Move a single algorithm run's contents up into its base dir.

    SPC and HDBSCAN both create a per-run subdirectory under ``base-dir``.
    For bench outputs, we want that base dir to contain the final run files
    directly, not another nested run folder.
    """
    run_dir = result.run_dir
    if run_dir.parent != parent_dir:
        return run_dir

    for child in run_dir.iterdir():
        target = parent_dir / child.name
        if target.exists():
            raise FileExistsError(
                f"Cannot flatten run dir {run_dir} because {target} already exists.")
        child.rename(target)
    run_dir.rmdir()
    return parent_dir


# ── Rendering ────────────────────────────────────────────────────────────────

def render_pack(
    spc,
    hdb,
    figures_dir: Path,
    *,
    include_3d: bool,
    dataset_name: str,
) -> None:
    """
    Write the standard benchmarking plot pack to ``figures_dir``. Every
    figure is closed after save so memory stays flat across long sweeps.
    """
    import matplotlib
    matplotlib.use("Agg")                 # no display required
    import matplotlib.pyplot as plt

    if __package__ is None:
        notebook_dir = Path(__file__).resolve().parents[1]
        if str(notebook_dir) not in sys.path:
            sys.path.insert(0, str(notebook_dir))
        from mvp.display import compare_runs, plot_sweep, plot_2x2_self
        from mvp.scatter import axis_pair_grid
    else:
        from .display import compare_runs, plot_sweep, plot_2x2_self
        from .scatter import axis_pair_grid

    def _save(fig, name: str) -> Path:
        path = figures_dir / name
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"  wrote {path}")
        return path

    # 1. SPC sweep observables
    if spc.sweep is not None:
        _save(plot_sweep(spc), "spc_sweep.png")

    # 2. Per-run pancake scatter (true vs predicted) — always works.
    _save(plot_2x2_self(spc), "spc_scatter.png")
    if hdb is not None:
        _save(plot_2x2_self(hdb), "hdbscan_scatter.png")

        # 3. Side-by-side 2×2 (SPC vs HDBSCAN, shared PCA basis)
        _save(compare_runs(spc, hdb, dataset_name=dataset_name), "compare_2x2.png")

    # 4. Axis-pair grids (honest 2D slices when D ≥ 3)
    if spc.dim >= 3:
        _save(axis_pair_grid(spc, label_type="predicted"), "spc_axis_pairs.png")
        if hdb is not None:
            _save(axis_pair_grid(hdb, label_type="predicted"), "hdbscan_axis_pairs.png")

    # 5. 3D — static PNG via matplotlib + interactive HTML via plotly
    if include_3d and spc.dim >= 3:
        _save_3d(spc, figures_dir, prefix="spc")
        if hdb is not None:
            _save_3d(hdb, figures_dir, prefix="hdbscan")


def _save_3d(result, figures_dir: Path, *, prefix: str) -> None:
    """Static PNG (matplotlib) + interactive HTML (plotly) when available."""
    save_mode = "compare" if result.true_labels is not None else "predicted"
    save_scatter3d_static(result, figures_dir / f"{prefix}_3d.png", mode=save_mode)
    print(f"  wrote {figures_dir / (prefix + '_3d.png')}")

    try:
        if __package__ is None:
            notebook_dir = Path(__file__).resolve().parents[1]
            if str(notebook_dir) not in sys.path:
                sys.path.insert(0, str(notebook_dir))
            from mvp.scatter3d import compare3d, scatter3d
        else:
            from .scatter3d import compare3d, scatter3d
        html_path = figures_dir / f"{prefix}_3d.html"
        fig = compare3d(result) if result.true_labels is not None else scatter3d(result, label_type="predicted")
        fig.write_html(str(html_path))
        print(f"  wrote {html_path}")
    except ImportError:
        # Plotly absent — static PNG is sufficient, just skip.
        pass


def save_scatter3d_static(result, path: Path, mode: str = "predicted") -> None:
    """
    matplotlib-only static 3D scatter (no plotly/kaleido). Uses the
    package palette so colours match the 2D figures.

    mode: "predicted" renders a single predicted panel.
          "compare" renders a side-by-side true vs predicted figure.
    """
    import matplotlib
    if matplotlib.get_backend().lower() != "agg":
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d import Axes3D  # noqa: F401 — registers 3d projection
    if __package__ is None:
        notebook_dir = Path(__file__).resolve().parents[1]
        if str(notebook_dir) not in sys.path:
            sys.path.insert(0, str(notebook_dir))
        from mvp.palette import label_colors, DEFAULT_TRUE_PALETTE, DEFAULT_PRED_PALETTE
    else:
        from .palette import label_colors, DEFAULT_TRUE_PALETTE, DEFAULT_PRED_PALETTE

    x, y, z = result.features[:, 0], result.features[:, 1], result.features[:, 2]
    if mode == "compare" and result.true_labels is not None:
        fig = plt.figure(figsize=(14, 6))
        ax_true = fig.add_subplot(121, projection="3d")
        ax_pred = fig.add_subplot(122, projection="3d")

        true_labels = result.true_labels
        pred_labels = result.predicted_labels
        true_colors = label_colors(true_labels, DEFAULT_TRUE_PALETTE)
        pred_colors = label_colors(pred_labels, DEFAULT_TRUE_PALETTE)

        ax_true.scatter(x, y, z, c=true_colors, s=20, alpha=0.7, edgecolors="none")
        ax_pred.scatter(x, y, z, c=pred_colors, s=20, alpha=0.7, edgecolors="none")

        for ax, title in ((ax_true, "True labels"), (ax_pred, "Predicted labels")):
            ax.set_xlabel("x0"); ax.set_ylabel("x1"); ax.set_zlabel("x2")
            ax.set_title(title, fontsize=10)

        fig.suptitle(
            f"{result.algorithm.upper()} · true vs predicted · {result.run_dir.name}",
            fontsize=11,
        )
    else:
        fig = plt.figure(figsize=(7, 6))
        ax = fig.add_subplot(111, projection="3d")
        labels = result.predicted_labels
        colors = label_colors(labels, DEFAULT_PRED_PALETTE)
        ax.scatter(x, y, z, c=colors, s=20, alpha=0.7, edgecolors="none")
        ax.set_xlabel("x0"); ax.set_ylabel("x1"); ax.set_zlabel("x2")
        ax.set_title(
            f"{result.algorithm.upper()} · predicted · {result.run_dir.name}",
            fontsize=10,
        )

    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    sys.exit(main())
