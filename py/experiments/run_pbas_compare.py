"""Phase comparison: ViBe variants vs PBAS variants on real clips.

4 methods × 2 sources × 200 frames. Outputs per source under
py/experiments/our_outputs/pbas_compare/<source>/:
  coverage.png           — 4-curve overlay (mean mask coverage vs frame)
  convergence_table.csv  — asymptote / peak / time-to-1%-coverage per method
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
    "pbas_default_raute4",
    "pbas_default_raute4_rcap",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/pbas_compare")
THRESHOLDS = [0.01, 0.001]


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


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        curves[method] = coverage_curve(masks)
    # coverage.png
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"ViBe vs PBAS — {source}",
    )
    # convergence_table.csv
    with (out_dir / "convergence_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "asymptote(last50)", "peak"]
                   + [f"t_to_{t:.4f}" for t in THRESHOLDS])
        for m in METHODS:
            c = curves[m]
            row = [m, f"{c[-50:].mean():.4f}", f"{c.max():.4f}"]
            for t in THRESHOLDS:
                tt = _time_to_threshold(c, t)
                row.append(str(tt) if tt is not None else "")
            w.writerow(row)
    print(f"[{source}] asymptote: " + ", ".join(
        f"{m}={curves[m][-50:].mean():.4f}" for m in METHODS), flush=True)


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
