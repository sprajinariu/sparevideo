"""ccl_bbox control flow: render the raw motion mask as a grey canvas with
green CCL bboxes overlaid. Debug view of CCL output."""

import numpy as np

from models.motion import (
    _rgb_to_y, _gauss3x3, _ema_update, _compute_mask,
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


def run(frames, thresh=16, alpha_shift=3, gauss_en=True, **kwargs):
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_ref = np.zeros((h, w), dtype=np.uint8)
    bboxes_state = [None] * N_OUT

    outputs = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur
        mask = _compute_mask(y_cur_filt, y_ref, thresh)

        canvas = _mask_to_grey_canvas(mask)
        out = _draw_bboxes(canvas, bboxes_state)

        new_bboxes = run_ccl(
            [mask],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed else [None] * N_OUT

        y_ref = _ema_update(y_cur_filt, y_ref, alpha_shift)
        outputs.append(out)

    return outputs
