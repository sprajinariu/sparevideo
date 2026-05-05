"""Post-run summary: re-load each source's mask sequences (ours, upstream, ema)
and emit per-source |ours - upstream| diffs + ghost-convergence numbers, suitable
for pasting into the decision-gate report.

Designed to be run AFTER `run_phase0.py --matrix all` has produced our_outputs/
and the upstream captures already exist under upstream_baseline_outputs/.
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from frames.video_source import load_frames
from experiments.metrics import (
    coverage_curve,
    ghost_convergence_frame,
    run_ema_baseline,
)
from experiments.motion_vibe import ViBe
from experiments.run_phase0 import (
    REAL_SOURCES,
    SYNTHETIC_SOURCES,
    _load_mask_sequence,
    _rgb_to_y,
)


def per_source_summary(source: str, num_frames: int = 200,
                       upstream_root: str = "py/experiments/upstream_baseline_outputs"):
    """Re-run our re-impl + load upstream + EMA, compute summary stats."""
    upstream_dir = Path(upstream_root) / source.replace(":", "_").replace("/", "_")

    frames_rgb = load_frames(source, width=320, height=240, num_frames=num_frames)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Our re-impl with matched params (K=20, R=20, phi=16)
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(frames_y[0])
    masks_ours = [np.zeros_like(frames_y[0], dtype=bool)]
    for f in frames_y[1:]:
        masks_ours.append(v.process_frame(f))

    # Upstream from disk (if available)
    masks_upstream = None
    if upstream_dir.exists():
        masks_upstream = _load_mask_sequence(str(upstream_dir), num_frames)

    # EMA baseline
    masks_ema = run_ema_baseline(frames_y)

    cov_ours = coverage_curve(masks_ours)
    cov_ema = coverage_curve(masks_ema)
    cov_up = coverage_curve(masks_upstream) if masks_upstream is not None else None

    diff_up = (
        float(np.abs(cov_ours - cov_up).mean()) if cov_up is not None else None
    )
    ghost_conv_ours = ghost_convergence_frame(cov_ours, threshold=0.05)
    ghost_conv_up = (
        ghost_convergence_frame(cov_up, threshold=0.05) if cov_up is not None else None
    )

    return {
        "source": source,
        "ours_avg": float(cov_ours.mean()),
        "ours_first8": float(cov_ours[:8].mean()),
        "ours_last32": float(cov_ours[-32:].mean()),
        "ema_avg": float(cov_ema.mean()),
        "upstream_avg": float(cov_up.mean()) if cov_up is not None else None,
        "diff_ours_minus_upstream_mean": diff_up,
        "ghost_conv_frame_ours": ghost_conv_ours,
        "ghost_conv_frame_upstream": ghost_conv_up,
    }


def main():
    sources = SYNTHETIC_SOURCES + REAL_SOURCES
    print(f"{'source':<50} {'ours':>7} {'upstr':>7} {'ema':>7} "
          f"{'|diff|':>7} {'gho_ours':>10} {'gho_up':>8}")
    print("-" * 100)
    for src in sources:
        s = per_source_summary(src)
        up = f"{s['upstream_avg']:.3f}" if s['upstream_avg'] is not None else "  —  "
        diff = f"{s['diff_ours_minus_upstream_mean']:.4f}" if s['diff_ours_minus_upstream_mean'] is not None else "  —  "
        gu = str(s['ghost_conv_frame_ours'])
        gup = str(s['ghost_conv_frame_upstream']) if s['ghost_conv_frame_upstream'] is not None else "—"
        print(f"{src:<50} {s['ours_avg']:>7.3f} {up:>7} {s['ema_avg']:>7.3f} "
              f"{diff:>7} {gu:>10} {gup:>8}")


if __name__ == "__main__":
    main()
