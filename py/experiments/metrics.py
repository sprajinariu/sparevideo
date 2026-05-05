"""Phase 0 metrics: mask-coverage curves, ghost-convergence detection, and an
EMA baseline runner that uses the existing project model for side-by-side
comparison.
"""

from typing import List

import numpy as np


def mask_coverage(mask: np.ndarray) -> float:
    """Return the fraction of pixels classified motion in a single mask."""
    return float(mask.sum()) / float(mask.size)


def coverage_curve(masks: List[np.ndarray]) -> np.ndarray:
    """Per-frame mask-coverage curve.

    Returns:
        (N,) float array, one entry per frame.
    """
    return np.array([mask_coverage(m) for m in masks])


def ghost_convergence_frame(curve: np.ndarray, threshold: float = 0.05) -> int:
    """First frame index at which the coverage curve drops below `threshold`
    *and stays below* for the remaining frames in the curve.

    Returns -1 if the curve never converges.
    """
    n = len(curve)
    for i in range(n):
        if curve[i] < threshold and (curve[i:] < threshold).all():
            return i
    return -1


def run_ema_baseline(frames: List[np.ndarray]) -> List[np.ndarray]:
    """Run the existing project EMA model on a list of Y frames.

    Wraps py/models/motion.py's compute_motion_masks for the Phase-0 comparison.

    Args:
        frames: list of (H, W) uint8 Y frames.

    Returns:
        list of (H, W) bool masks, one per input frame.
    """
    # Convert Y → RGB triple (the model expects RGB) by replicating the channel
    rgb_frames = [np.stack([f, f, f], axis=-1) for f in frames]

    from models.motion import compute_motion_masks
    masks = compute_motion_masks(rgb_frames)
    # compute_motion_masks returns numpy bool arrays; convert any that aren't
    return [np.asarray(m, dtype=bool) for m in masks]
