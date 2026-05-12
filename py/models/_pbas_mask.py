"""Private helper — produce per-frame motion masks via the PBAS operator.

Parallel to models/_vibe_mask.py. Takes RGB frames, converts to Y, applies
optional Gaussian pre-filter, runs PBAS, returns per-frame boolean masks.
"""
from __future__ import annotations

import numpy as np

from models.motion import _gauss3x3, _rgb_to_y
from models.ops.pbas import PBAS


def produce_masks_pbas(
    frames: list[np.ndarray],
    *,
    pbas_N: int,
    pbas_R_lower: int,
    pbas_R_scale: int,
    pbas_Raute_min: int,
    pbas_T_lower: int,
    pbas_T_upper: int,
    pbas_T_init: int,
    pbas_R_incdec_q8: int,
    pbas_T_inc_q8: int,
    pbas_T_dec_q8: int,
    pbas_alpha: int,
    pbas_beta: int,
    pbas_mean_mag_min: int,
    pbas_bg_init_lookahead: int,
    pbas_prng_seed: int,
    pbas_R_upper: int = 0,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
    """Return per-frame boolean motion masks under PBAS."""
    if not frames:
        return []
    # Convert RGB → Y, optionally gauss-prefilter.
    y_stack = []
    for f in frames:
        y = _rgb_to_y(f)
        y_stack.append(_gauss3x3(y) if gauss_en else y)
    # Recover float values from Q8 fixed-point.
    R_incdec = pbas_R_incdec_q8 / 256.0
    T_inc = pbas_T_inc_q8 / 256.0
    T_dec = pbas_T_dec_q8 / 256.0
    p = PBAS(
        N=pbas_N, R_lower=pbas_R_lower, R_scale=pbas_R_scale,
        Raute_min=pbas_Raute_min, T_lower=pbas_T_lower, T_upper=pbas_T_upper,
        T_init=pbas_T_init, R_incdec=R_incdec, T_inc=T_inc, T_dec=T_dec,
        alpha=pbas_alpha, beta=pbas_beta,
        mean_mag_min=float(pbas_mean_mag_min),
        prng_seed=pbas_prng_seed,
        R_upper=pbas_R_upper,
    )
    masks: list[np.ndarray] = []
    if pbas_bg_init_lookahead == 0:
        # Paper-default: first N frames seed bank, no processing.
        assert len(y_stack) >= pbas_N, \
            f"pbas_default init needs >= N={pbas_N} frames; got {len(y_stack)}"
        p.init_from_frames(y_stack[:pbas_N], mode="paper_default")
        # Emit all-zero masks for init frames.
        zero = np.zeros(y_stack[0].shape, dtype=bool)
        masks.extend([zero.copy() for _ in range(pbas_N)])
        # Process remaining frames normally.
        for i in range(pbas_N, len(y_stack)):
            masks.append(p.process_frame(y_stack[i]))
    elif pbas_bg_init_lookahead == 1:
        # Lookahead: seed bank from temporal median of all frames, then process from 0.
        p.init_from_frames(y_stack, mode="lookahead_median")
        for y in y_stack:
            masks.append(p.process_frame(y))
    else:
        raise ValueError(f"unknown pbas_bg_init_lookahead {pbas_bg_init_lookahead}")
    return masks
