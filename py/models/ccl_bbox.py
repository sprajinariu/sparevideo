"""ccl_bbox control flow: render the raw motion mask as a grey canvas with
green CCL bboxes overlaid. Debug view of CCL output."""

import numpy as np

from models.motion import (
    _rgb_to_y, _gauss3x3, _selective_ema_update, _compute_mask,
    _draw_bboxes, PRIME_FRAMES, N_OUT, N_LABELS_INT,
    MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
)
from models.ccl import run_ccl

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


def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, gauss_en=True,
        **kwargs):
    """ccl_bbox reference model.

    Frame 0: hard-init bg = Y_smooth; mask forced to zero; no bboxes drawn.
    Frame N>0: selective EMA — motion pixels at slow rate, non-motion at fast.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    bboxes_state = [None] * N_OUT
    primed = False

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
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
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
