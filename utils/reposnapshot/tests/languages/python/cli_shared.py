"""Shared CLI helpers for notebook-level benchmark and analysis scripts."""

from __future__ import annotations

import argparse


def add_dataset_args(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    """Add dataset-related CLI options shared by SPC and HDBSCAN runs."""
    parser.add_argument(
        "--dataset",
        default="BlattHierarchy",
        help="Synthetic generator name. Ignored when --dataset-file is set.",
    )
    parser.add_argument(
        "--dataset-file",
        help="CSV input instead of synthetic.",
    )
    parser.add_argument(
        "--label-column",
        default="label",
        help="Label column name for --dataset-file.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed used by both SPC and HDBSCAN.",
    )
    return parser


def add_config_args(parser: argparse.ArgumentParser, *, include_hdbscan: bool = False) -> argparse.ArgumentParser:
    """Add config-file flags for SPC and optionally HDBSCAN."""
    parser.add_argument(
        "--spc-config",
        help="Path to an SPC preset JSON file.",
    )
    if include_hdbscan:
        parser.add_argument(
            "--hdbscan-config",
            help="Path to an HDBSCAN preset JSON file.",
        )
    return parser
