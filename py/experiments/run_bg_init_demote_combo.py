"""Exploratory: compare MVTW alone vs MVTW + demote on the 3 real clips.

4 methods over 3 sources:
  vibe_init_external  — baseline (lookahead-median, no demote)
  vibe_demote         — current production demote (frame-0 init + demote)
  vibe_init_mvtw      — Task 10's winner (MVTW init alone, no demote)
  vibe_init_demote    — new combo: MVTW init + demote (in-line override; no profile registration)

Outputs:
  py/experiments/our_outputs/bg_init_demote_combo/<source>/{coverage.png, table.csv}
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from experiments.metrics import coverage_curve
from experiments.render import render_coverage_curves
from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/intersection-320x240.mp4",
    "media/source/people-320x240.mp4",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/bg_init_demote_combo")
ASYMPTOTE_WINDOW = 50


def _coverage_by_region(masks):
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)
    time_avg = stack.mean(axis=0)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]
    ht = float(tail[:, high_traffic].mean()) if high_traffic.any() else float("nan")
    lt = float(tail[:, ~high_traffic].mean()) if (~high_traffic).any() else float("nan")
    return ht, lt


def _resolve_cfg(name: str) -> dict:
    """Returns a cfg dict for produce_masks_vibe."""
    if name == "vibe_init_demote":
        # In-line combo: vibe_init_mvtw (MVTW init) + demote knobs from VIBE_DEMOTE.
        cfg = dict(resolve("vibe_init_mvtw"))
        cfg["vibe_demote_en"] = True
        cfg["vibe_demote_K_persist"] = 30
        cfg["vibe_demote_kernel"] = 3
        cfg["vibe_demote_consistency_thresh"] = 3
        return cfg
    return dict(resolve(name))


METHODS = [
    "vibe_init_external",
    "vibe_demote",
    "vibe_init_mvtw",
    "vibe_init_demote",
]


def _produce_masks(method: str, frames):
    cfg = _resolve_cfg(method)
    return produce_masks_vibe(
        frames,
        **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
    )


def run_source(source: str, n_frames: int = N_FRAMES) -> dict:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames; need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    rows = []
    for m in METHODS:
        masks = _produce_masks(m, frames)
        curve = coverage_curve(masks)
        curves[m] = curve
        ht, lt = _coverage_by_region(masks)
        rows.append([m, f"{curve[-ASYMPTOTE_WINDOW:].mean():.4f}",
                     f"{ht:.4f}", f"{lt:.4f}", f"{curve.max():.4f}"])
        print(f"[{source}] {m}: asym={curve[-ASYMPTOTE_WINDOW:].mean():.4f}  "
              f"HT={ht:.4f}  LT={lt:.4f}", flush=True)
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"MVTW vs MVTW+demote — {source}",
    )
    with (out_dir / "table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", f"asymptote(last{ASYMPTOTE_WINDOW})",
                    "asymptote_high_traffic", "asymptote_low_traffic", "peak"])
        w.writerows(rows)
    return {m: float(curves[m][-ASYMPTOTE_WINDOW:].mean()) for m in METHODS}


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
