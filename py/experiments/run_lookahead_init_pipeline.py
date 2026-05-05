"""Follow-up validation for the ViBe look-ahead-median-init experiment.

Runs the canonical baseline (frame-0 init) and the winning look-ahead
mode through the production motion pipeline (gauss3x3 -> ViBe ->
morph_open -> morph_close) on the three real demo clips. Confirms that
the headline-experiment win survives pre/post-processing.

This script runs only after run_lookahead_init.py has identified a
clear winner. Edit WINNING_MODE below if a different mode is chosen.

Companion design doc: docs/plans/2026-05-05-vibe-lookahead-init-design.md
"""

import sys
from pathlib import Path
from typing import Dict, List

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from frames.video_source import load_frames
from experiments.motion_vibe import ViBe
from experiments.metrics import coverage_curve
from experiments.render import render_grid, render_coverage_curves
from models.motion import _gauss3x3
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


# === EDIT BEFORE RUNNING: pick the winner from the headline experiment. ===
WINNING_MODE = "init_lookahead_full"
# ==========================================================================

VIBE_PARAMS = dict(
    K=20, R=20, min_match=2,
    phi_update=16, phi_diffuse=16,
    init_scheme="c", coupled_rolls=True,
    prng_seed=0xDEADBEEF,
)

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/our_outputs/lookahead_init_pipeline")

# Production-pipeline morph_close kernel (CFG_DEFAULT in sparevideo_pkg.sv).
MORPH_CLOSE_KERNEL = 3


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def _init_vibe(frames_y_stack: np.ndarray, init_mode: str) -> ViBe:
    v = ViBe(**VIBE_PARAMS)
    if init_mode == "init_frame0":
        v.init_from_frame(frames_y_stack[0])
    elif init_mode == "init_lookahead_n20":
        n = min(20, frames_y_stack.shape[0])
        v.init_from_frames(frames_y_stack, lookahead_n=n)
    elif init_mode == "init_lookahead_full":
        v.init_from_frames(frames_y_stack, lookahead_n=None)
    else:
        raise ValueError(f"unknown init_mode {init_mode!r}")
    return v


def _run_pipeline(frames_y_stack: np.ndarray, init_mode: str) -> List[np.ndarray]:
    """Run gauss -> ViBe -> morph_open -> morph_close end-to-end. Return cleaned masks."""
    v = _init_vibe(frames_y_stack, init_mode)
    cleaned: List[np.ndarray] = []
    for f in frames_y_stack:
        f_blur = _gauss3x3(f)
        raw_mask = v.process_frame(f_blur)            # bool (H, W)
        opened = morph_open(raw_mask)                 # bool (H, W)
        closed = morph_close(opened, kernel=MORPH_CLOSE_KERNEL)  # bool (H, W)
        cleaned.append(closed)
    return cleaned


def run_source(source: str, num_frames: int = 200,
               width: int = 320, height: int = 240) -> Dict:
    frames_rgb = load_frames(source, width=width, height=height,
                             num_frames=num_frames)
    frames_y_list = [_rgb_to_y(f) for f in frames_rgb]
    frames_y = np.stack(frames_y_list, axis=0)

    modes = ["init_frame0", WINNING_MODE]
    masks_per_mode = {m: _run_pipeline(frames_y, m) for m in modes}

    safe = source.replace(":", "_").replace("/", "_")
    out_dir = OUT_ROOT / safe
    out_dir.mkdir(parents=True, exist_ok=True)

    curves = {m: coverage_curve(masks_per_mode[m]) for m in modes}
    render_coverage_curves(
        curves, out_path=str(out_dir / "coverage.png"),
        title=f"{source}  |  pipeline (gauss + morph_open + morph_close)  "
              f"|  baseline vs {WINNING_MODE}",
    )

    rows = [(m, masks_per_mode[m]) for m in modes]
    render_grid(frames_rgb, rows, out_path=str(out_dir / "grid.png"))

    return {
        "source": source,
        "out_dir": str(out_dir),
        "curves": {m: c.tolist() for m, c in curves.items()},
    }


def main() -> int:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for src in SOURCES:
        print(f"=== {src} ===", flush=True)
        result = run_source(src)
        for mode, c in result["curves"].items():
            arr = np.asarray(c)
            print(f"  {mode}: avg={arr.mean():.4f}  max={arr.max():.4f}",
                  flush=True)
    print(f"\nDone. Outputs under {OUT_ROOT}/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
