"""ccl_bbox control-flow reference model — ViBe bg variant.

Same grey-canvas-with-bboxes render as models/ccl_bbox.py, with ViBe
replacing EMA for mask production. Reuses the EMA module's
_mask_to_grey_canvas helper and BG_GREY/FG_GREY constants so canvas
values stay in lockstep across the two variants.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ccl import run_ccl
from models.ccl_bbox import _mask_to_grey_canvas, BG_GREY, FG_GREY  # noqa: F401
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
    if not frames:
        return []
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
    for i in range(len(frames)):
        canvas = _mask_to_grey_canvas(cleaned[i])
        out = _draw_bboxes(canvas, bboxes_state)
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
