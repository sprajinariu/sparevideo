"""ccl_bbox control flow: render the raw motion mask as a grey canvas with
green CCL bboxes overlaid. Debug view of CCL output."""

import numpy as np

from models.motion import (
    _rgb_to_y, _gauss3x3, _ema_update, _selective_ema_update, _compute_mask,
    _draw_bboxes, PRIME_FRAMES, N_OUT, N_LABELS_INT,
    MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
)
from models.ccl import run_ccl
from models.ops.morph_open import morph_open

BG_GREY    = np.array([0x20, 0x20, 0x20], dtype=np.uint8)
FG_GREY    = np.array([0x80, 0x80, 0x80], dtype=np.uint8)
BBOX_COLOR = np.array([0x00, 0xFF, 0x00], dtype=np.uint8)


def _mask_to_grey_canvas(mask):
    """Expand 1-bit mask to a 24-bit grey canvas (FG_GREY where motion, BG_GREY elsewhere)."""
    h, w = mask.shape
    out = np.empty((h, w, 3), dtype=np.uint8)
    out[...] = BG_GREY
    out[mask] = FG_GREY
    return out


def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        grace_alpha_shift=1, gauss_en=True, morph_en=True, **kwargs):
    """ccl_bbox reference model.

    Frame 0: hard-init bg = Y_smooth; mask forced to zero; no bboxes drawn.
    Frames 1..grace_frames: fast-EMA grace window — bg updates use fast rate
    regardless of mask. Suppresses frame-0 hard-init ghosts.
    Frame > grace_frames: selective EMA — motion pixels at slow rate, non-motion at fast.

    morph_en (default True): apply 3x3 morphological opening to the mask
    before it reaches the grey canvas and CCL. The EMA uses the raw
    (pre-morph) mask so its behaviour matches the RTL datapath.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    bboxes_state = [None] * N_OUT
    primed = False
    grace_cnt = 0

    outputs = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur

        if not primed:
            # Frame 0: hard-init bg, mask forced to zero
            mask = np.zeros((h, w), dtype=bool)
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            raw_mask = _compute_mask(y_cur_filt, y_bg, thresh)
            # Morph opening cleans the mask for display and CCL; EMA uses
            # raw_mask to match the RTL datapath.
            clean_mask = morph_open(raw_mask) if morph_en else raw_mask
            in_grace = grace_cnt < grace_frames
            # During grace, mask is forced to 0 so the ghost region is not
            # displayed or fed to CCL; bg still converges at fast rate.
            mask = np.zeros_like(clean_mask) if in_grace else clean_mask
            if in_grace:
                y_bg = _ema_update(y_cur_filt, y_bg, grace_alpha_shift)
                grace_cnt += 1
            else:
                y_bg = _selective_ema_update(y_cur_filt, y_bg, raw_mask,
                                             alpha_shift, alpha_shift_slow)

        canvas = _mask_to_grey_canvas(mask)
        out = _draw_bboxes(canvas, bboxes_state)

        new_bboxes = run_ccl(
            [mask],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT

        outputs.append(out)

    return outputs
