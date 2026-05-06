"""Per-frame bbox-count helper for the HUD model. Mirrors the count the SV
emits via popcount over u_ccl_bboxes.valid[].

Branches on bg_model so the HUD count is correct under ViBe profiles too."""
from __future__ import annotations

from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    compute_motion_masks,
)
from models.ops.morph_open import morph_open

_BG_MODEL_EMA = 0
_BG_MODEL_VIBE = 1


def bbox_counts_per_frame(ctrl_flow: str, frames, *, bg_model=_BG_MODEL_EMA,
                           motion_thresh=16, alpha_shift=3, alpha_shift_slow=6,
                           grace_frames=0, grace_alpha_shift=1, gauss_en=True,
                           morph_open_en=True, morph_close_en=False,
                           morph_close_kernel=3, **vibe_kwargs) -> list[int]:
    """Number of valid bboxes per frame matching SV's u_ccl_bboxes.valid popcount.
    Returns zeros for non-bbox-producing flows (passthrough)."""
    if ctrl_flow == "passthrough":
        return [0] * len(frames)

    if bg_model == _BG_MODEL_VIBE:
        from models._vibe_mask import produce_masks_vibe
        # Drop EMA-only kwargs and tail-stage flags before forwarding.
        for k in ("motion_thresh", "alpha_shift", "alpha_shift_slow",
                  "grace_frames", "grace_alpha_shift",
                  "morph_open_en", "morph_close_en", "morph_close_kernel",
                  "hflip_en", "gamma_en", "scaler_en", "hud_en", "bbox_color"):
            vibe_kwargs.pop(k, None)
        masks = produce_masks_vibe(frames, gauss_en=gauss_en, **vibe_kwargs)
    else:
        masks = compute_motion_masks(
            frames,
            motion_thresh=motion_thresh, alpha_shift=alpha_shift,
            alpha_shift_slow=alpha_shift_slow, grace_frames=grace_frames,
            grace_alpha_shift=grace_alpha_shift, gauss_en=gauss_en,
        )

    if morph_open_en:
        masks = [morph_open(m) for m in masks]
    bboxes_per_frame = run_ccl(masks, n_out=N_OUT,
                               n_labels_int=N_LABELS_INT,
                               min_component_pixels=MIN_COMPONENT_PIXELS,
                               max_chain_depth=MAX_CHAIN_DEPTH)
    return [sum(1 for b in bb if b is not None) for bb in bboxes_per_frame]
