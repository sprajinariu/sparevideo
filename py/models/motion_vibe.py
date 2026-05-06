"""Motion control-flow reference model — ViBe bg variant.

Same head/tail as models/motion.py (RGB→Y, gauss, morph_clean, CCL,
overlay) but the bg-subtraction block is ViBe instead of EMA. Wired in
when the active profile sets `bg_model = BG_MODEL_VIBE = 1`.

Frame-0 priming convention matches the EMA path: mask is all-zero on
frame 0, no bboxes drawn. From frame 1 onward the ViBe bank produces
masks normally. See models/_vibe_mask.py for the shared producer.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    PRIME_FRAMES, _draw_bboxes,
)
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


def run(
    frames: list[np.ndarray],
    *,
    morph_open_en: bool = True,
    morph_close_en: bool = True,
    morph_close_kernel: int = 3,
    **vibe_kwargs,
) -> list[np.ndarray]:
    """Motion ctrl_flow under ViBe bg.

    Reuses motion.py constants and _draw_bboxes for parity with the EMA
    output convention. Per-frame steps:
      1. produce_masks_vibe → raw mask
      2. morph_open  (if enabled)
      3. morph_close (if enabled)
      4. run_ccl on the cleaned mask → bboxes (1-frame delay vs EMA path)
      5. _draw_bboxes(prev frame's bboxes, current rgb frame)
    """
    if not frames:
        return []

    # ViBe needs the unfiltered RGB stack; the helper handles gauss internally.
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)

    cleaned: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        cleaned.append(c)

    bboxes_state = [None] * N_OUT
    outputs: list[np.ndarray] = []
    for i, frame in enumerate(frames):
        out = _draw_bboxes(frame, bboxes_state)
        new_bboxes = run_ccl(
            [cleaned[i]],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT
        outputs.append(out)

    return outputs
