"""Headline driver for the ViBe look-ahead-median-init experiment.

For each of five sources, runs three init modes — canonical frame-0 init
(baseline), look-ahead median over N=20 frames, and look-ahead median over
all frames — on raw ViBe (no pre/post pipeline). Emits per-source coverage
curves and a side-by-side mask grid under
py/experiments/our_outputs/lookahead_init/<source>/.

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


# Phase-0-validated default ViBe params — see 2026-05-04-vibe-phase-0-results.md.
VIBE_PARAMS = dict(
    K=20, R=20, min_match=2,
    phi_update=16, phi_diffuse=16,
    init_scheme="c", coupled_rolls=True,
    prng_seed=0xDEADBEEF,
)

# Headline sources (Question 5 of brainstorm: 2 ghost stress + 3 real clips).
SOURCES = [
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/our_outputs/lookahead_init")


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    """Project Y8 extraction (matches rgb2ycrcb.sv): Y = (77*R + 150*G + 29*B) >> 8."""
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def _run_one_init_mode(
    frames_y_stack: np.ndarray,
    init_mode: str,
) -> List[np.ndarray]:
    """Construct a fresh ViBe, init it according to `init_mode`, then run all
    frames through process_frame. Returns the list of per-frame bool masks.

    init_mode is one of:
      'init_frame0'         — vibe.init_from_frame(frames_y_stack[0])
      'init_lookahead_n20'  — vibe.init_from_frames(stack, lookahead_n=20)
      'init_lookahead_full' — vibe.init_from_frames(stack, lookahead_n=None)
    """
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
    masks = [v.process_frame(f) for f in frames_y_stack]
    return masks


def run_source(source: str, num_frames: int = 200,
               width: int = 320, height: int = 240) -> Dict:
    """Run all three init modes on a single source; render + return curves."""
    frames_rgb = load_frames(source, width=width, height=height,
                             num_frames=num_frames)
    frames_y_list = [_rgb_to_y(f) for f in frames_rgb]
    frames_y = np.stack(frames_y_list, axis=0)  # (N, H, W) uint8

    modes = ["init_frame0", "init_lookahead_n20", "init_lookahead_full"]
    masks_per_mode = {m: _run_one_init_mode(frames_y, m) for m in modes}

    # Output directory: replace ':' and '/' for filesystem safety.
    safe = source.replace(":", "_").replace("/", "_")
    out_dir = OUT_ROOT / safe
    out_dir.mkdir(parents=True, exist_ok=True)

    # Coverage curves
    curves = {m: coverage_curve(masks_per_mode[m]) for m in modes}
    render_coverage_curves(
        curves, out_path=str(out_dir / "coverage.png"),
        title=f"{source}  |  K={VIBE_PARAMS['K']}  φu={VIBE_PARAMS['phi_update']}  "
              f"φd={VIBE_PARAMS['phi_diffuse']}  init=lookahead-median experiment",
    )

    # Grid
    rows = [(m, masks_per_mode[m]) for m in modes]
    render_grid(frames_rgb, rows, out_path=str(out_dir / "grid.png"))

    return {
        "source": source,
        "out_dir": str(out_dir),
        "curves": {m: c.tolist() for m, c in curves.items()},
    }


def main() -> int:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    summary: List[Dict] = []
    for src in SOURCES:
        print(f"=== {src} ===", flush=True)
        result = run_source(src)
        summary.append(result)
        # Brief per-source stat: avg coverage per mode.
        for mode, c in result["curves"].items():
            arr = np.asarray(c)
            print(f"  {mode}: avg={arr.mean():.4f}  max={arr.max():.4f}",
                  flush=True)
    print(f"\nDone. Outputs under {OUT_ROOT}/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
