"""One-knob sweep per mode on people-320x240.mp4 — locks in per-mode defaults.

Sweeps:
  IMRM: imrm_tau ∈ {12, 20, 32}  (imrm_iters=3 fixed)
  MVTW: mvtw_k   ∈ {12, 24, 60}
  MAM:  mam_delta ∈ {6, 12}     (mam_dilate=2 fixed)

Outputs:
  py/experiments/our_outputs/bg_init_compare/_sweep/summary.csv
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from experiments.metrics import coverage_curve
from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCE = "media/source/people-320x240.mp4"
N_FRAMES = 200
OUT_DIR = Path("py/experiments/our_outputs/bg_init_compare/_sweep")
ASYMPTOTE_WINDOW = 50

SWEEPS = [
    # (label, base_profile, override_field, value)
    ("imrm_tau12", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 12),
    ("imrm_tau20", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 20),
    ("imrm_tau32", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 32),
    ("mvtw_k12",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   12),
    ("mvtw_k24",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   24),
    ("mvtw_k60",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   60),
    ("mam_delta6",  "vibe_init_mam", "vibe_bg_init_mam_delta", 6),
    ("mam_delta12", "vibe_init_mam", "vibe_bg_init_mam_delta", 12),
]


def _coverage_by_region(masks):
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)
    time_avg = stack.mean(axis=0)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]
    ht_cov = float(tail[:, high_traffic].mean()) if high_traffic.any() else float("nan")
    low_traffic = ~high_traffic
    lt_cov = float(tail[:, low_traffic].mean()) if low_traffic.any() else float("nan")
    return ht_cov, lt_cov


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    frames = load_frames(SOURCE, width=320, height=240, num_frames=N_FRAMES)
    rows = []
    for label, base_profile, field, value in SWEEPS:
        cfg = dict(resolve(base_profile))
        cfg[field] = value
        masks = produce_masks_vibe(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
        )
        curve = coverage_curve(masks)
        ht, lt = _coverage_by_region(masks)
        rows.append([
            label, base_profile, field, value,
            f"{curve[-ASYMPTOTE_WINDOW:].mean():.4f}",
            f"{ht:.4f}", f"{lt:.4f}",
        ])
        print(f"[{label}] asym={curve[-ASYMPTOTE_WINDOW:].mean():.4f}  "
              f"high_traffic={ht:.4f}  low_traffic={lt:.4f}", flush=True)
    with (OUT_DIR / "summary.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["label", "base_profile", "field", "value",
                    "asymptote_overall", "asymptote_high_traffic", "asymptote_low_traffic"])
        w.writerows(rows)


if __name__ == "__main__":
    main()
