"""Mask control-flow reference model — ViBe bg variant.

Same B/W expansion as models/mask.py, with ViBe replacing EMA for
mask production. Mask cleanup (morph_open/close) is applied identically.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
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
    """Mask ctrl_flow under ViBe bg. Returns per-frame B/W RGB frames."""
    if not frames:
        return []
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)
    h, w = raw_masks[0].shape
    outputs: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        # Expand boolean mask to white-on-black RGB (matches mask.py:96-97).
        out = np.zeros((h, w, 3), dtype=np.uint8)
        out[c] = 255
        outputs.append(out)
    return outputs
