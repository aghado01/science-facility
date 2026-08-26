"""
datasets.py — Loaders for external dataset formats that the spcx CLI
cannot consume directly.

The spcx CLI accepts (a) synthetic-generator names and (b) CSV feature
matrices via ``--dataset-file``. External datasets that live in other
formats (precomputed distance matrices, sparse k-NN lists, MCL matrix
dumps) need a Python-side adapter that:

  1. Parses the source format.
  2. Recovers an approximate feature embedding (typically classical MDS
     when only pairwise distances are available).
  3. Writes a CSV the CLI's ``--dataset-file`` flag can ingest.

Currently supported sources:

* **Domany SPC_N format** — ``datasets/reference/spc_n/data`` and
  similar. Two-section file: sparse k-NN headers followed by an MCL
  dense distance matrix. Parser handles both; downstream consumers see
  a unified :class:`SpcNDataset`. The companion ``model`` output file
  is parsed by :func:`load_spc_n_model` so spcx runs can be compared
  against Domany's own clustering as a "second ground truth."
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np

__all__ = [
    "SpcNDataset",
    "SpcNModel",
    "load_spc_n_data",
    "load_spc_n_model",
    "embed_via_mds",
    "save_features_csv",
    "load_spc_n_example",
]


# ── DTOs ────────────────────────────────────────────────────────────────────

@dataclass
class SpcNDataset:
    """One Domany-format dataset: pairwise distances + per-point labels."""
    names:            list[str]               # point IDs as strings (file order)
    distance_matrix:  np.ndarray              # (N, N) symmetric, with self-distances as sentinel
    labels:           Optional[np.ndarray]    # (N,) int or None when absent
    source_path:      Path                    # where the file was loaded from

    @property
    def n_points(self) -> int:
        return len(self.names)


@dataclass
class SpcNModel:
    """One Domany-format SPC run output (.model file)."""
    temperatures:   np.ndarray                # (T,) the parameter sweep grid
    susceptibility: np.ndarray                # (T,) chi(T)
    cluster_matrix: np.ndarray                # (N, T) cluster id per (point, temperature)
    names:          list[str]                 # (N,) point IDs aligned to rows
    labels:         Optional[np.ndarray]      # (N,) per-point class labels if present
    source_path:    Path


# ── Domany SPC_N parsers ────────────────────────────────────────────────────

# Sentinel for "this is my own distance" in the MCL matrix section.
_SELF_DISTANCE_SENTINEL = 141.42

# Regexes are simple enough not to need to share state; compile once on
# import.
_RE_NAME       = re.compile(r"^#NAME\s+(\S+)\s*$")
_RE_DISTANCES  = re.compile(r"^#DISTANCES\s+(.*?)\s*$")
_RE_LABELS     = re.compile(r"^#LABELS\s+(.*?)\s*$")
_RE_ALLNAMES   = re.compile(r"^#ALLNAMES\s+(.*?)\s*$")
_RE_PARAMETER  = re.compile(r"^#PARAMETER\s+(\S+)\s+(\S+)\s+(\d+)\s*$")
_RE_SUSCEPT    = re.compile(r"^#SUSCEPTIBILITY\s+(.*?)\s*$")
_RE_CLUSTERS   = re.compile(r"^#CLUSTERS\s+(.*?)\s*$")
_RE_MCL_BEGIN  = re.compile(r"^\(mclmatrix\s*$")
_RE_MCL_ROW    = re.compile(r"^(\d+)\s+(.*?)\s*\$\s*$")


def load_spc_n_data(path: str | Path) -> SpcNDataset:
    """
    Parse a Domany SPC_N ``data`` file (the two-section format used by
    Fernando Chaure's wave_clus / Domany's reference impl).

    Strategy: prefer the dense MCL matrix when present (most accurate),
    fall back to the sparse k-NN section otherwise (builds a sparse
    matrix with ``inf`` for missing pairs).
    """
    path = Path(path)
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    # First pass: collect everything from both sections.
    names, labels = _parse_spcn_headers(lines)
    sparse = _parse_spcn_sparse_distances(lines, name_to_idx={n: i for i, n in enumerate(names)})
    dense  = _parse_spcn_mcl_matrix(lines)

    n = len(names)
    if n == 0:
        raise ValueError(f"No #NAME entries found in {path}.")

    if dense is not None:
        # Dense MCL matrix is authoritative when present. The MCL row
        # indices are 0-based and may not align 1:1 with the names list
        # ordering — verify shape and re-zero the self-distance sentinel
        # for downstream consumers.
        if dense.shape != (n, n):
            raise ValueError(
                f"MCL matrix shape {dense.shape} doesn't match #ALLNAMES count {n}.")
        D = dense.copy()
    else:
        if not sparse:
            raise ValueError(
                f"{path}: neither dense MCL matrix nor sparse #DISTANCES section parseable.")
        D = _materialise_sparse(sparse, n)

    # Replace the self-distance sentinel with 0 — downstream tooling
    # (sklearn MDS, scipy spatial) expects literal zeros on the diagonal.
    D[np.isclose(D, _SELF_DISTANCE_SENTINEL)] = 0.0
    np.fill_diagonal(D, 0.0)

    return SpcNDataset(
        names           = names,
        distance_matrix = D,
        labels          = labels,
        source_path     = path,
    )


def load_spc_n_model(path: str | Path) -> SpcNModel:
    """Parse a Domany SPC_N ``model`` output file."""
    path = Path(path)
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    temperatures   = None
    susceptibility = None
    rows: list[tuple[str, list[int], Optional[int]]] = []

    cur_name: Optional[str] = None
    cur_clusters: Optional[list[int]] = None
    cur_label:   Optional[int]        = None

    for line in lines:
        if (m := _RE_PARAMETER.match(line)):
            tmin, tmax, ntemps = float(m.group(1)), float(m.group(2)), int(m.group(3))
            # The Domany impl log-spaces by default; reconstructing exactly
            # would need the impl's own grid logic, but the linear stub is
            # close enough for downstream display alignment. Callers that
            # need the exact grid can post-hoc replace temperatures with
            # whatever they actually requested.
            temperatures = np.linspace(tmin, tmax, ntemps)
        elif (m := _RE_SUSCEPT.match(line)):
            susceptibility = np.fromstring(m.group(1), sep=" ")
        elif (m := _RE_NAME.match(line)):
            if cur_name is not None and cur_clusters is not None:
                rows.append((cur_name, cur_clusters, cur_label))
            cur_name, cur_clusters, cur_label = m.group(1), None, None
        elif (m := _RE_CLUSTERS.match(line)):
            cur_clusters = [int(x) for x in m.group(1).split()]
        elif (m := _RE_LABELS.match(line)):
            try: cur_label = int(m.group(1))
            except ValueError: cur_label = None

    if cur_name is not None and cur_clusters is not None:
        rows.append((cur_name, cur_clusters, cur_label))

    if not rows:
        raise ValueError(f"{path}: no #NAME / #CLUSTERS rows parseable.")
    if temperatures is None:
        raise ValueError(f"{path}: no #PARAMETER line found.")

    n_points = len(rows)
    n_temps  = len(rows[0][1])
    names    = [r[0] for r in rows]
    cluster_matrix = np.array([r[1] for r in rows], dtype=int)
    labels = (np.array([r[2] for r in rows], dtype=int)
              if all(r[2] is not None for r in rows) else None)

    if cluster_matrix.shape != (n_points, n_temps):
        raise ValueError(
            f"{path}: ragged #CLUSTERS rows ({cluster_matrix.shape} vs {n_points}×{n_temps}).")

    return SpcNModel(
        temperatures   = temperatures,
        susceptibility = susceptibility if susceptibility is not None else np.array([]),
        cluster_matrix = cluster_matrix,
        names          = names,
        labels         = labels,
        source_path    = path,
    )


# ── Embedding + CSV writing ─────────────────────────────────────────────────

def embed_via_mds(
    dataset: SpcNDataset,
    n_components: int = 3,
    *,
    metric: bool = True,
    random_state: int = 42,
    **mds_kwargs,
) -> np.ndarray:
    """
    Recover an Euclidean feature embedding from the distance matrix via
    sklearn MDS. ``n_components=3`` is the default since most synthetic
    datasets the spcx CLI ships with live in 3D — keeps the same scatter
    plotters useful.
    """
    try:
        from sklearn.manifold import MDS
    except ImportError as e:
        raise ImportError("sklearn not installed — required for embed_via_mds.") from e

    import warnings
    # sklearn 1.x is renaming MDS params (`dissimilarity` → `metric`,
    # `metric` → `metric_mds`, new `n_init`/`init` defaults). The
    # current call is correct for sklearn < 1.10; suppress the noise
    # so notebook output stays readable.
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", FutureWarning)
        mds = MDS(
            n_components       = n_components,
            dissimilarity      = "precomputed",
            metric             = metric,
            n_init             = 4,
            random_state       = random_state,
            normalized_stress  = "auto",
            **mds_kwargs,
        )
        return mds.fit_transform(dataset.distance_matrix)


def save_features_csv(
    features: np.ndarray,
    path: str | Path,
    *,
    labels: Optional[np.ndarray] = None,
    label_column: str = "label",
) -> Path:
    """
    Write features (and optional labels) in the CSV shape ``userrepl spc
    --dataset-file`` expects: header row + numeric columns. Label column
    name matches the CLI's default ``--label-column`` lookup.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    n, dim = features.shape
    cols = [f"feature_{d}" for d in range(dim)]
    if labels is not None:
        if labels.shape != (n,):
            raise ValueError(f"Labels shape {labels.shape} doesn't match features {features.shape}.")
        cols.append(label_column)

    with path.open("w", encoding="utf-8") as f:
        f.write(",".join(cols) + "\n")
        for i in range(n):
            row = [f"{features[i, d]:.10g}" for d in range(dim)]
            if labels is not None:
                row.append(str(int(labels[i])))
            f.write(",".join(row) + "\n")
    return path


def load_spc_n_example(
    example_dir: str | Path = "datasets/reference/spc_n",
    *,
    n_components: int = 3,
    out_csv: Optional[Path] = None,
    root: Optional[Path] = None,
) -> tuple[Path, SpcNDataset, Optional[SpcNModel]]:
    """
    One-call convenience for the bundled Chaure / Domany example:

      1. Parse the ``data`` file.
      2. MDS-embed into ``n_components`` Euclidean dims.
      3. Write a CSV ready for ``Spcx spc --dataset-file <csv>``.
      4. Parse the ``model`` file if present (for "Domany's own SPC"
         baseline comparison).

    Returns ``(csv_path, dataset, model_or_None)``.
    """
    if root is not None:
        example_dir = Path(root) / example_dir
    example_dir = Path(example_dir)
    data_path   = example_dir / "data"
    model_path  = example_dir / "model"

    dataset  = load_spc_n_data(data_path)
    features = embed_via_mds(dataset, n_components=n_components)

    out_csv = Path(out_csv) if out_csv is not None else (example_dir / "embedded_features.csv")
    save_features_csv(features, out_csv, labels=dataset.labels)

    model = load_spc_n_model(model_path) if model_path.exists() else None
    return out_csv, dataset, model


# ── Internals ───────────────────────────────────────────────────────────────

def _parse_spcn_headers(lines: list[str]) -> tuple[list[str], Optional[np.ndarray]]:
    """Walk the file once to gather ``#ALLNAMES`` + per-point ``#LABELS``."""
    names: list[str] = []
    labels: list[int] = []
    cur_name: Optional[str] = None
    saw_allnames = False

    for line in lines:
        if (m := _RE_ALLNAMES.match(line)) and not saw_allnames:
            names = m.group(1).split()
            saw_allnames = True
        elif (m := _RE_NAME.match(line)):
            cur_name = m.group(1)
            if not saw_allnames:
                names.append(cur_name)
        elif (m := _RE_LABELS.match(line)) and cur_name is not None:
            try: labels.append(int(m.group(1)))
            except ValueError: pass

    label_arr = np.array(labels, dtype=int) if len(labels) == len(names) and labels else None
    return names, label_arr


def _parse_spcn_sparse_distances(
    lines: list[str], name_to_idx: dict[str, int],
) -> list[tuple[int, list[tuple[int, float]]]]:
    """Collect per-point sparse k-NN distances from the ``#DISTANCES`` lines."""
    out: list[tuple[int, list[tuple[int, float]]]] = []
    cur_name: Optional[str] = None
    for line in lines:
        if (m := _RE_NAME.match(line)):
            cur_name = m.group(1)
        elif (m := _RE_DISTANCES.match(line)) and cur_name is not None:
            tokens = m.group(1).split()
            pairs: list[tuple[int, float]] = []
            # Format: "<id> <dist> <id> <dist> ..." — must be even count.
            for k in range(0, len(tokens) - 1, 2):
                try:
                    nbr_id   = tokens[k]
                    distance = float(tokens[k + 1])
                except (ValueError, IndexError):
                    continue
                if nbr_id in name_to_idx:
                    pairs.append((name_to_idx[nbr_id], distance))
            if cur_name in name_to_idx:
                out.append((name_to_idx[cur_name], pairs))
    return out


def _materialise_sparse(
    sparse: list[tuple[int, list[tuple[int, float]]]], n: int,
) -> np.ndarray:
    """Sparse k-NN list → dense distance matrix (``inf`` for missing pairs)."""
    D = np.full((n, n), np.inf, dtype=float)
    np.fill_diagonal(D, 0.0)
    for src, pairs in sparse:
        for dst, dist in pairs:
            D[src, dst] = dist
            D[dst, src] = min(D[dst, src], dist)   # symmetrize on the fly
    return D


def _parse_spcn_mcl_matrix(lines: list[str]) -> Optional[np.ndarray]:
    """
    Parse the trailing ``(mclmatrix begin ... )`` section. Returns None
    when the section is absent or malformed.
    """
    in_section = False
    rows: dict[int, dict[int, float]] = {}
    max_idx = -1

    for line in lines:
        if _RE_MCL_BEGIN.match(line):
            in_section = True
            continue
        if not in_section:
            continue
        if line.strip() in {")", "end"}:
            break
        if (m := _RE_MCL_ROW.match(line)):
            row_idx = int(m.group(1))
            body    = m.group(2)
            row: dict[int, float] = {}
            for token in body.split():
                if ":" not in token:
                    continue
                try:
                    col_str, val_str = token.split(":", 1)
                    row[int(col_str)] = float(val_str)
                except ValueError:
                    continue
            rows[row_idx] = row
            max_idx = max(max_idx, row_idx, *row.keys())

    if not rows:
        return None

    n = max_idx + 1
    D = np.zeros((n, n), dtype=float)
    for r, cols in rows.items():
        for c, v in cols.items():
            D[r, c] = v
    return D
