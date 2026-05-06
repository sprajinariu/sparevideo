"""Private helper — produce per-frame motion masks via the ViBe operator.

Single source of truth used by motion_vibe / mask_vibe / ccl_bbox_vibe.
Mirrors the structure of motion.compute_motion_masks (which uses EMA),
swapping the bg block for a `models.ops.vibe.ViBe` instance.

Frame-0 priming convention matches the EMA path: the first output mask is
all-zero (the ViBe bank is being initialised, no motion can be reported).
For lookahead-median init, the bank is seeded from the median of N frames
of the input clip (or all frames when N=0), so frame 0 already has a
realistic bg estimate — the all-zero priming convention is a deliberate
match-the-EMA-path choice, NOT a ViBe limitation.
"""
from __future__ import annotations

import numpy as np

from models.motion import _gauss3x3, _rgb_to_y
from models.ops.vibe import ViBe


def produce_masks_vibe(
    frames: list[np.ndarray],
    *,
    vibe_K: int,
    vibe_R: int,
    vibe_min_match: int,
    vibe_phi_update: int,
    vibe_phi_diffuse: int,
    vibe_init_scheme: int,
    vibe_prng_seed: int,
    vibe_coupled_rolls: bool,
    vibe_bg_init_mode: int,
    vibe_bg_init_lookahead_n: int,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
    """Return per-frame uint8 motion masks (True/False as 0/1) under ViBe."""
    if not frames:
        return []

    # Pre-compute the Y stack (gaussian-filtered if enabled).
    y_stack = []
    for f in frames:
        y = _rgb_to_y(f)
        y_stack.append(_gauss3x3(y) if gauss_en else y)
    y_arr = np.stack(y_stack, axis=0)  # (N, H, W) uint8

    init_scheme = {0: "a", 1: "b", 2: "c"}[vibe_init_scheme]
    v = ViBe(
        K=vibe_K,
        R=vibe_R,
        min_match=vibe_min_match,
        phi_update=vibe_phi_update,
        phi_diffuse=vibe_phi_diffuse,
        init_scheme=init_scheme,
        prng_seed=vibe_prng_seed,
        coupled_rolls=vibe_coupled_rolls,
    )

    # Init.
    if vibe_bg_init_mode == 0:           # frame0
        v.init_from_frame(y_arr[0])
    elif vibe_bg_init_mode == 1:         # lookahead median
        n = None if vibe_bg_init_lookahead_n == 0 else int(vibe_bg_init_lookahead_n)
        v.init_from_frames(y_arr, lookahead_n=n)
    else:
        raise ValueError(f"unknown vibe_bg_init_mode {vibe_bg_init_mode}")

    # Per-frame mask production. Frame 0 is priming → all-zero (matches EMA path).
    h, w = y_arr.shape[1:]
    masks: list[np.ndarray] = [np.zeros((h, w), dtype=bool)]
    for i in range(1, y_arr.shape[0]):
        masks.append(v.process_frame(y_arr[i]))
    return masks
