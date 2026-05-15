"""BG-estimate helpers for ViBe look-ahead initialisation.

Each helper consumes an (N, H, W) uint8 luma stack and returns an (H, W) uint8
per-pixel BG estimate. The estimate then feeds the same K-slot bank-seeding
path that the existing lookahead-median path uses (compute_lookahead_median_bank
in py/models/motion_vibe.py, and init_from_frame in py/models/ops/vibe.py).

Companion design / plan:
  docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md
"""
from __future__ import annotations

import numpy as np


def compute_bg_estimate(
    y_stack: np.ndarray,
    *,
    mode: str = "median",
    imrm_tau: int = 20,
    imrm_iters: int = 3,
    mvtw_k: int = 24,
    mam_delta: int = 8,
    mam_dilate: int = 2,
) -> np.ndarray:
    """Compute a per-pixel BG estimate from an (N, H, W) uint8 luma stack.

    Args:
        y_stack: (N, H, W) uint8 stack of luma frames, N >= 1.
        mode:    "median" | "imrm" | "mvtw" | "mam"
        imrm_tau, imrm_iters: IMRM knobs.
        mvtw_k:               MVTW knob.
        mam_delta, mam_dilate: MAM knobs.

    Returns:
        (H, W) uint8 BG estimate.
    """
    assert y_stack.ndim == 3 and y_stack.dtype == np.uint8, \
        "y_stack must be (N, H, W) uint8"
    assert y_stack.shape[0] >= 1, "y_stack must have at least 1 frame"
    if mode == "median":
        return np.median(y_stack, axis=0).astype(np.uint8)
    if mode == "imrm":
        return _bg_imrm(y_stack, tau=int(imrm_tau), iters=int(imrm_iters))
    if mode == "mvtw":
        return _bg_mvtw(y_stack, k=int(mvtw_k))
    if mode == "mam":
        return _bg_mam(y_stack, delta=int(mam_delta), dilate=int(mam_dilate))
    raise ValueError(f"unknown bg_init mode {mode!r}")


def _bg_imrm(y_stack: np.ndarray, *, tau: int, iters: int) -> np.ndarray:
    """Iterative motion-rejected median.

    Initialise BG estimate as the plain temporal median. On each iteration,
    mark per-pixel frames where |I_t - bg_est| > tau as outliers; recompute
    the median over inliers only via a NaN-masked per-pixel median
    (np.nanmedian). Pixels where all frames are flagged outliers keep the
    previous iteration's value.
    """
    bg = np.median(y_stack, axis=0).astype(np.float32)  # (H, W)
    for _ in range(iters):
        diff = np.abs(y_stack.astype(np.float32) - bg[None, :, :])  # (N, H, W)
        outlier = diff > float(tau)
        replaced = np.where(outlier, np.nan, y_stack.astype(np.float32))
        with np.errstate(invalid="ignore"):
            new_bg = np.nanmedian(replaced, axis=0)
        # All-outlier pixels: keep previous iteration's bg.
        all_outlier = outlier.all(axis=0)
        bg = np.where(all_outlier, bg, new_bg)
    return np.clip(bg, 0, 255).astype(np.uint8)


def _bg_mvtw(y_stack: np.ndarray, *, k: int) -> np.ndarray:
    """Per-pixel min-variance temporal window.

    For each pixel, slide a K-frame window across the stack, compute the
    variance of the K samples, pick the window with minimum variance, and
    return that window's mean. On ties, prefer the MOST RECENT window —
    when FG passes through a pixel and BG is revealed later in the clip,
    the latest min-variance window is the BG-clear segment we want.

    If N < K (clip shorter than the window), fall back to plain median over
    the full stack.

    Vectorised via np.lib.stride_tricks.sliding_window_view.
    """
    n, h, w = y_stack.shape
    if n < k:
        return np.median(y_stack, axis=0).astype(np.uint8)
    # sliding_window_view on axis 0 → shape (n-k+1, h, w, k).
    windows = np.lib.stride_tricks.sliding_window_view(
        y_stack.astype(np.float32), window_shape=k, axis=0
    )
    # variance per window per pixel → shape (n-k+1, h, w).
    var = windows.var(axis=-1)
    # argmin window index per pixel with recency tie-break:
    # reverse along the window axis, take argmin (first occurrence in the
    # reversed view = last occurrence in the original), and map back.
    n_win = var.shape[0]
    best = (n_win - 1) - var[::-1].argmin(axis=0)
    # Gather the chosen window's mean per pixel.
    means = windows.mean(axis=-1)  # (n-k+1, h, w)
    ii, jj = np.indices((h, w))
    bg = means[best, ii, jj]
    return np.clip(bg, 0, 255).astype(np.uint8)


def _bg_mam(y_stack: np.ndarray, *, delta: int, dilate: int) -> np.ndarray:
    """Motion-aware median (frame-diff outlier rejection).

    Two passes:
      1. Compute per-pixel inter-frame absolute deltas; threshold by `delta`
         to get a binary motion mask of shape (N, H, W). Frame 0 is treated
         as motion (conservative) and frames N-1 inherits N-2's diff.
      2. Temporally dilate the motion mask by `dilate` frames in both
         directions (so a motion event shadows neighbouring frames). Then
         per pixel, take median over frames NOT flagged as motion. Pixels
         with zero non-motion frames fall back to plain median over the
         full stack.
    """
    n, h, w = y_stack.shape
    if n == 1:
        return y_stack[0].copy()
    y = y_stack.astype(np.int16)
    # Frame-to-frame absolute delta, shape (n, h, w). Frame 0 = delta with frame 1.
    diff = np.empty((n, h, w), dtype=np.int16)
    diff[0] = np.abs(y[1] - y[0])
    diff[1:n-1] = np.maximum(np.abs(y[1:n-1] - y[0:n-2]),
                             np.abs(y[2:n]   - y[1:n-1]))
    diff[n-1] = np.abs(y[n-1] - y[n-2])
    motion = diff > int(delta)  # (n, h, w) bool
    # Temporal dilation by `dilate` frames in both directions.
    if dilate > 0:
        dilated = motion.copy()
        for d in range(1, int(dilate) + 1):
            dilated[d:] |= motion[:-d]
            dilated[:-d] |= motion[d:]
        motion = dilated
    # Per pixel, median over non-motion frames. Use a mask-aware approach:
    # replace motion frames with NaN, then nanmedian.
    yf = y_stack.astype(np.float32)
    yf[motion] = np.nan
    # all-motion fallback to plain median over the original stack
    all_motion = motion.all(axis=0)  # (h, w) bool
    with np.errstate(invalid="ignore"):
        bg = np.nanmedian(yf, axis=0)  # may be NaN where all-motion
    if all_motion.any():
        fallback = np.median(y_stack, axis=0).astype(np.float32)
        bg = np.where(all_motion, fallback, bg)
    return np.clip(bg, 0, 255).astype(np.uint8)
