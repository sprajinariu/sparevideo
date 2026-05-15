"""5×5 benchmark: 4 bg_init modes + vibe_demote control over 5 standard sources.

Method list:
  vibe_init_external   (current production baseline: lookahead-median)
  vibe_init_imrm
  vibe_init_mvtw
  vibe_init_mam
  vibe_demote          (runtime control: lookahead-median init + persistence demote)

Source list:
  media/source/birdseye-320x240.mp4
  media/source/intersection-320x240.mp4
  media/source/people-320x240.mp4
  synthetic:ghost_box_disappear
  synthetic:ghost_box_moving

Outputs under py/experiments/our_outputs/bg_init_compare/<source>/:
  coverage.png            — coverage curves
  convergence_table.csv   — asymptote / peak / time-to-thresh per method
  coverage_by_region.csv  — high-traffic vs low-traffic asymptote split
  grid.webp               — side-by-side mask grid (one row per method)

Companion design / plan:
  docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.metrics import coverage_curve
from experiments.render import render_coverage_curves
from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/intersection-320x240.mp4",
    "media/source/people-320x240.mp4",
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
]
METHODS = [
    "vibe_init_external",
    "vibe_init_imrm",
    "vibe_init_mvtw",
    "vibe_init_mam",
    "vibe_demote",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/bg_init_compare")
THRESHOLDS = [0.01, 0.001]
ASYMPTOTE_WINDOW = 50  # frames 150-199 of a 200-frame run


def _produce_masks(profile_name: str, frames):
    cfg = dict(resolve(profile_name))
    return produce_masks_vibe(
        frames,
        **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
    )


def _time_to_threshold(curve: np.ndarray, t: float) -> int | None:
    below = np.where(curve < t)[0]
    return int(below[0]) if below.size else None


def _coverage_by_region(masks):
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)
    time_avg = stack.mean(axis=0)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]
    ht_cov = float(tail[:, high_traffic].mean()) if high_traffic.any() else float("nan")
    low_traffic = ~high_traffic
    lt_cov = float(tail[:, low_traffic].mean()) if low_traffic.any() else float("nan")
    return ht_cov, lt_cov


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    region_cov: dict[str, tuple[float, float]] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        curves[method] = coverage_curve(masks)
        region_cov[method] = _coverage_by_region(masks)
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"BG init compare — {source}",
    )
    with (out_dir / "convergence_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            ["method", f"asymptote(last{ASYMPTOTE_WINDOW})", "peak"]
            + [f"t_to_{t:.4f}" for t in THRESHOLDS]
        )
        for m in METHODS:
            c = curves[m]
            row = [m, f"{c[-ASYMPTOTE_WINDOW:].mean():.4f}", f"{c.max():.4f}"]
            for t in THRESHOLDS:
                tt = _time_to_threshold(c, t)
                row.append(str(tt) if tt is not None else "")
            w.writerow(row)
    with (out_dir / "coverage_by_region.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "asymptote_high_traffic", "asymptote_low_traffic"])
        for m in METHODS:
            ht, lt = region_cov[m]
            w.writerow([m, f"{ht:.4f}", f"{lt:.4f}"])
    print(f"[{source}] asymptote: " + ", ".join(
        f"{m}={curves[m][-ASYMPTOTE_WINDOW:].mean():.4f}" for m in METHODS), flush=True)
    print(f"[{source}] high-traffic asymptote: " + ", ".join(
        f"{m}={region_cov[m][0]:.4f}" for m in METHODS), flush=True)


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
