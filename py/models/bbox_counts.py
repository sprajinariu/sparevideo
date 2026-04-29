"""Per-frame bbox-count helper for the HUD model. Mirrors the count the SV
emits via popcount over u_ccl_bboxes.valid[]."""
from __future__ import annotations
from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    compute_motion_masks,
)
from models.ops.morph_open import morph_open


def bbox_counts_per_frame(ctrl_flow: str, frames, *, motion_thresh, alpha_shift,
                           alpha_shift_slow, grace_frames, grace_alpha_shift,
                           gauss_en, morph_en, **_ignored) -> list[int]:
    """Number of valid bboxes per frame matching what SV's u_ccl_bboxes.valid
    popcount would yield. Returns zeros for non-bbox-producing flows."""
    # passthrough bypasses CCL entirely; every other flow (motion, mask,
    # ccl_bbox) runs CCL inside motion_pipe_active so the bbox sideband is
    # populated and the HUD's popcount-of-valid-lanes is non-zero.
    if ctrl_flow == "passthrough":
        return [0] * len(frames)

    masks = compute_motion_masks(frames,
                                  motion_thresh=motion_thresh,
                                  alpha_shift=alpha_shift,
                                  alpha_shift_slow=alpha_shift_slow,
                                  grace_frames=grace_frames,
                                  grace_alpha_shift=grace_alpha_shift,
                                  gauss_en=gauss_en)
    if morph_en:
        masks = [morph_open(m) for m in masks]
    bboxes_per_frame = run_ccl(masks, n_out=N_OUT,
                               n_labels_int=N_LABELS_INT,
                               min_component_pixels=MIN_COMPONENT_PIXELS,
                               max_chain_depth=MAX_CHAIN_DEPTH)
    return [sum(1 for b in bb if b is not None) for bb in bboxes_per_frame]
