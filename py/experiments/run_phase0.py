"""Phase 0 driver: run our ViBe re-impl + EMA baseline on a single source,
capture per-frame masks, compute coverage curves, render side-by-side outputs.

This module exposes `run_source()` (one-source runner) and a `__main__` entry
point that drives the full Phase-0 matrix (called from Task 13 onward).

Upstream PyTorch reference outputs are NOT produced here — they're captured
once by Task 14 and read from disk (gitignored at py/experiments/upstream_baseline_outputs/).
"""

import os
import sys
from pathlib import Path
from typing import Dict, Optional

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from frames.video_source import load_frames
from experiments.motion_vibe import ViBe
from experiments.metrics import coverage_curve, run_ema_baseline
from experiments.render import render_grid, render_coverage_curves


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    """Project Y8 extraction (matches rgb2ycrcb.sv): Y = (77*R + 150*G + 29*B) >> 8."""
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def run_source(
    source: str,
    num_frames: int = 64,
    width: int = 320,
    height: int = 240,
    K: int = 20,
    R: int = 20,
    min_match: int = 2,
    phi_update: int = 16,
    phi_diffuse: int = 16,
    init_scheme: str = "c",
    prng_seed: int = 0xDEADBEEF,
    coupled_rolls: bool = True,
    out_dir: Optional[str] = None,
    upstream_masks_dir: Optional[str] = None,
) -> Dict:
    """Run our ViBe + EMA baseline on a single source. Optionally include upstream.

    Default `coupled_rolls=True` matches upstream's canonical behavior (one
    PRNG roll determines both self-update and diffusion firing on the same
    pixel under shared probability 1/phi_update). Doc B §2's two-phi
    generalization is selected by passing `coupled_rolls=False`.

    Returns:
        dict with keys: coverage_curve_ours, coverage_curve_ema, coverage_curve_upstream
        (last only if upstream_masks_dir is provided), out_dir.
    """
    frames_rgb = load_frames(source, width=width, height=height, num_frames=num_frames)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Our ViBe
    v = ViBe(
        K=K, R=R, min_match=min_match,
        phi_update=phi_update, phi_diffuse=phi_diffuse,
        init_scheme=init_scheme, prng_seed=prng_seed,
        coupled_rolls=coupled_rolls,
    )
    v.init_from_frame(frames_y[0])
    masks_ours = [np.zeros_like(frames_y[0], dtype=bool)]  # frame 0 = init only
    for f in frames_y[1:]:
        masks_ours.append(v.process_frame(f))

    # EMA baseline (existing project model)
    masks_ema = run_ema_baseline(frames_y)

    # Optional upstream reference (loaded from pre-captured PNG sequence)
    masks_upstream = None
    if upstream_masks_dir is not None and Path(upstream_masks_dir).exists():
        masks_upstream = _load_mask_sequence(upstream_masks_dir, num_frames)

    # Compute curves
    cov_ours = coverage_curve(masks_ours)
    cov_ema = coverage_curve(masks_ema)
    curves = {"ours (ViBe)": cov_ours, "ema (current)": cov_ema}
    if masks_upstream is not None:
        cov_up = coverage_curve(masks_upstream)
        curves["upstream (PyTorch ViBe)"] = cov_up

    # Render
    rows = [("ours", masks_ours), ("ema", masks_ema)]
    if masks_upstream is not None:
        rows.insert(1, ("upstream", masks_upstream))

    if out_dir is not None:
        os.makedirs(out_dir, exist_ok=True)
        render_grid(frames_rgb, rows, out_path=os.path.join(out_dir, "grid.png"))
        render_coverage_curves(
            curves, out_path=os.path.join(out_dir, "coverage.png"),
            title=f"{source} | K={K} R={R} φu={phi_update} φd={phi_diffuse} init={init_scheme}",
        )

    result = {
        "source": source,
        "coverage_curve_ours": cov_ours,
        "coverage_curve_ema": cov_ema,
        "out_dir": out_dir,
    }
    if masks_upstream is not None:
        result["coverage_curve_upstream"] = cov_up
    return result


def _load_mask_sequence(dir_path: str, num_frames: int) -> list:
    """Load a sequence of PNG masks (single-channel, 0=bg, 255=motion) into bools."""
    from PIL import Image
    p = Path(dir_path)
    masks = []
    for i in range(num_frames):
        f = p / f"mask_{i:05d}.png"
        img = np.array(Image.open(f).convert("L"))
        masks.append(img > 127)
    return masks


def _first_cleared_frame(coverage: np.ndarray, threshold: float = 0.005,
                         consecutive: int = 8) -> int:
    """Return first frame index F such that coverage[F:F+consecutive] all < threshold.

    Returns len(coverage) if the ghost never clears within the window.
    """
    n = len(coverage)
    for f in range(n - consecutive + 1):
        if np.all(coverage[f:f + consecutive] < threshold):
            return f
    return n


SYNTHETIC_SOURCES = [
    "synthetic:moving_box",
    "synthetic:dark_moving_box",
    "synthetic:noisy_moving_box",
    "synthetic:textured_static",
    "synthetic:lighting_ramp",
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
]

REAL_SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]


def run_synthetic_matrix(
    out_root: str = "py/experiments/our_outputs/synthetic",
    upstream_root: str = "py/experiments/upstream_baseline_outputs",
    num_frames: int = 200,
):
    """Run each synthetic source at default ViBe parameters; include upstream
    captures when available (mirrors run_real_matrix)."""
    results = []
    for src in SYNTHETIC_SOURCES:
        out_dir = os.path.join(out_root, src.replace(":", "_").replace("/", "_"))
        upstream_dir = os.path.join(upstream_root, src.replace(":", "_").replace("/", "_"))
        upstream = upstream_dir if os.path.isdir(upstream_dir) else None
        result = run_source(
            source=src, num_frames=num_frames, out_dir=out_dir,
            upstream_masks_dir=upstream,
        )
        results.append(result)
        line = (f"  {src}: ours_avg={result['coverage_curve_ours'].mean():.3f}  "
                f"ema_avg={result['coverage_curve_ema'].mean():.3f}")
        if 'coverage_curve_upstream' in result:
            line += f"  upstream_avg={result['coverage_curve_upstream'].mean():.3f}"
        print(line)
    return results


def run_real_matrix(out_root: str = "py/experiments/our_outputs/real",
                    upstream_root: str = "py/experiments/upstream_baseline_outputs",
                    num_frames: int = 200):
    """Run each real-world clip; include upstream masks if captured."""
    results = []
    for src in REAL_SOURCES:
        out_dir = os.path.join(out_root, src.replace("/", "_"))
        upstream_dir = os.path.join(upstream_root, src.replace("/", "_"))
        upstream = upstream_dir if os.path.isdir(upstream_dir) else None
        result = run_source(
            source=src, num_frames=num_frames, out_dir=out_dir,
            upstream_masks_dir=upstream,
        )
        results.append(result)
        print(f"  {src}: ours_avg={result['coverage_curve_ours'].mean():.3f}  "
              f"ema_avg={result['coverage_curve_ema'].mean():.3f}"
              + (f"  upstream_avg={result['coverage_curve_upstream'].mean():.3f}"
                 if 'coverage_curve_upstream' in result else ""))
    return results


def run_k_comparison(out_root: str = "py/experiments/our_outputs/k_comparison",
                     upstream_root: str = "py/experiments/upstream_baseline_outputs",
                     num_frames: int = 200):
    """Compare K=8 vs K=20 on noisy_moving_box (real motion + per-pixel noise).

    Includes upstream parity check (upstream is captured at K=20). The K=8 row
    therefore tells us the parity cost of dropping K vs the K=20 baseline.
    """
    src = "synthetic:noisy_moving_box"
    upstream_dir = os.path.join(upstream_root, src.replace(":", "_"))
    upstream = upstream_dir if os.path.isdir(upstream_dir) else None
    results = {}
    for K in (8, 20):
        out_dir = os.path.join(out_root, f"K{K}")
        result = run_source(
            source=src, num_frames=num_frames, K=K,
            out_dir=out_dir,
            upstream_masks_dir=upstream,
        )
        results[K] = result
        avg = result["coverage_curve_ours"].mean()
        steady = result["coverage_curve_ours"][32:].mean()
        line = f"  K={K}: avg={avg:.3f}  steady-state(32+)={steady:.3f}"
        if "coverage_curve_upstream" in result:
            up = result["coverage_curve_upstream"]
            ours = result["coverage_curve_ours"]
            per_frame_diff = float(np.abs(ours - up).mean())
            line += f"  |ours-upstream|={per_frame_diff:.4f}"
        print(line)
    return results


def run_negative_control(out_root: str = "py/experiments/our_outputs/negative_control",
                         num_frames: int = 200):
    """Run with phi_diffuse=0 to ablate diffusion. Expect frame-0 ghost
    to persist on synthetic:ghost_box_disappear (validates diffusion is the fix)."""
    src = "synthetic:ghost_box_disappear"
    out_dir = os.path.join(out_root, "phi_diffuse_0")
    result = run_source(
        source=src, num_frames=num_frames, phi_diffuse=0,
        out_dir=out_dir,
    )
    avg = result["coverage_curve_ours"].mean()
    end = result["coverage_curve_ours"][-32:].mean()  # last 32 frames
    print(f"  phi_diffuse=0 on {src}: avg={avg:.3f}  end-state={end:.3f}")
    return result


def run_init_scheme_comparison(
    out_root: str = "py/experiments/our_outputs/init_schemes",
    num_frames: int = 200,
):
    """Compare frame-0 init schemes (a) neighborhood / (b) degenerate / (c) noise
    on the ghost-test synthetic patterns."""
    sources = ["synthetic:ghost_box_disappear", "synthetic:ghost_box_moving"]
    results = {}
    for src in sources:
        for scheme in ("a", "b", "c"):
            out_dir = os.path.join(
                out_root, src.replace(":", "_"), f"scheme_{scheme}"
            )
            result = run_source(
                source=src, num_frames=num_frames, init_scheme=scheme,
                out_dir=out_dir,
            )
            avg = result["coverage_curve_ours"].mean()
            results[(src, scheme)] = avg
            print(f"  {src} scheme {scheme}: avg={avg:.3f}")
    return results


def run_phi_diffuse_sweep(
    out_root: str = "py/experiments/our_outputs/phi_diffuse_sweep",
    upstream_root: str = "py/experiments/upstream_baseline_outputs",
    num_frames: int = 200,
):
    """Sweep phi_diffuse over {16, 8, 4, 2, 1} on synthetic:ghost_box_disappear
    with coupled_rolls=False to characterize ghost-decay control.

    Renders one combined grid (5 ours-rows + upstream + ema) and one combined
    coverage plot. Prints per-φ first-cleared-frame metric.
    """
    os.makedirs(out_root, exist_ok=True)
    src = "synthetic:ghost_box_disappear"
    width, height = 320, 240

    frames_rgb = load_frames(src, width=width, height=height, num_frames=num_frames)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    phi_values = [16, 8, 4, 2, 1]
    rows = []
    curves = {}
    print("=== phi_diffuse sweep on", src, "(coupled_rolls=False) ===")
    for phi in phi_values:
        v = ViBe(
            K=20, R=20, min_match=2,
            phi_update=16, phi_diffuse=phi,
            init_scheme="c", prng_seed=0xDEADBEEF,
            coupled_rolls=False,
        )
        v.init_from_frame(frames_y[0])
        masks = [np.zeros_like(frames_y[0], dtype=bool)]
        for f in frames_y[1:]:
            masks.append(v.process_frame(f))
        rows.append((f"ours φd={phi}", masks))
        cov = coverage_curve(masks)
        curves[f"ours φd={phi}"] = cov
        cleared = _first_cleared_frame(cov)
        cleared_str = f"{cleared}" if cleared < num_frames else f">{num_frames}"
        print(f"  φd={phi}: avg={cov.mean():.3f}  first-cleared-frame={cleared_str}")

    upstream_dir = os.path.join(upstream_root, src.replace(":", "_"))
    if os.path.isdir(upstream_dir):
        masks_up = _load_mask_sequence(upstream_dir, num_frames)
        rows.append(("upstream (canonical)", masks_up))
        curves["upstream (canonical)"] = coverage_curve(masks_up)

    masks_ema = run_ema_baseline(frames_y)
    rows.append(("ema", masks_ema))
    curves["ema"] = coverage_curve(masks_ema)

    render_grid(frames_rgb, rows, out_path=os.path.join(out_root, "grid.png"))
    render_coverage_curves(
        curves, out_path=os.path.join(out_root, "coverage.png"),
        title=f"{src} | phi_diffuse sweep | coupled_rolls=False",
    )
    return curves


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--matrix", choices=[
        "synthetic", "real", "k_comparison", "negative_control",
        "init_schemes", "phi_diffuse_sweep", "all"
    ], default="synthetic")
    args = p.parse_args()
    if args.matrix in ("synthetic", "all"):
        print("=== Synthetic matrix ===")
        run_synthetic_matrix()
    if args.matrix in ("real", "all"):
        print("=== Real matrix ===")
        run_real_matrix()
    if args.matrix in ("k_comparison", "all"):
        print("=== K=8 vs K=20 stress-test ===")
        run_k_comparison()
    if args.matrix in ("negative_control", "all"):
        print("=== Negative control (phi_diffuse=0) ===")
        run_negative_control()
    if args.matrix in ("phi_diffuse_sweep", "all"):
        print("=== phi_diffuse sweep ===")
        run_phi_diffuse_sweep()
    if args.matrix in ("init_schemes", "all"):
        print("=== Frame-0 init scheme comparison ===")
        run_init_scheme_comparison()
