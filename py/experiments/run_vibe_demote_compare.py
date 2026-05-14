"""Phase comparison: vibe_demote vs reference methods on real clips.

4 methods x 2 sources x 200 frames. Outputs under
py/experiments/our_outputs/vibe_demote_compare/<source>/:
  coverage.png            — coverage curves
  convergence_table.csv   — asymptote (frames 150-199) / peak / time-to-thresh per method
  coverage_by_region.csv  — high-traffic vs low-traffic asymptote split

Companion design / plan:
  docs/plans/2026-05-12-vibe-demote-python-design.md
  docs/plans/2026-05-12-vibe-demote-python-plan.md
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
from models._pbas_mask import produce_masks_pbas
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
]
METHODS = [
    "vibe_init_frame0",
    "vibe_init_external",
    "pbas_default",
    "vibe_demote",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/vibe_demote_compare")
THRESHOLDS = [0.01, 0.001]
ASYMPTOTE_WINDOW = 50  # frames 150-199 of a 200-frame run


def _produce_masks(profile_name: str, frames: list[np.ndarray]) -> list[np.ndarray]:
    cfg = dict(resolve(profile_name))
    if profile_name.startswith("pbas_"):
        return produce_masks_pbas(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("pbas_") or k == "gauss_en"},
        )
    elif profile_name.startswith("vibe_"):
        return produce_masks_vibe(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
        )
    else:
        raise ValueError(f"unknown profile family: {profile_name}")


def _time_to_threshold(curve: np.ndarray, t: float) -> int | None:
    below = np.where(curve < t)[0]
    return int(below[0]) if below.size else None


def _coverage_by_region(masks: list[np.ndarray]) -> tuple[float, float]:
    """Split coverage into (high-traffic, low-traffic) regions.

    A pixel is in the high-traffic region if its time-averaged FG-classification
    rate exceeds 50% across the run. The two returned values are the asymptote
    coverage (frames 150-199 mean) restricted to each region.
    """
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)  # (T, H, W)
    time_avg = stack.mean(axis=0)                                  # (H, W)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]                               # (50, H, W)
    if high_traffic.any():
        ht_cov = float(tail[:, high_traffic].mean())
    else:
        ht_cov = float("nan")
    low_traffic = ~high_traffic
    if low_traffic.any():
        lt_cov = float(tail[:, low_traffic].mean())
    else:
        lt_cov = float("nan")
    return ht_cov, lt_cov


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    region_cov: dict[str, tuple[float, float]] = {}
    method_masks: dict[str, list[np.ndarray]] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        method_masks[method] = masks
        curves[method] = coverage_curve(masks)
        region_cov[method] = _coverage_by_region(masks)
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"ViBe-demote vs reference — {source}",
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
