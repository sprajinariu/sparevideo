"""Mask display control flow reference model.

Displays the 1-bit motion mask (optionally cleaned by 3x3 morphological
opening) as a black-and-white image. Reuses the motion pipeline's luma
extraction and frame-difference mask logic, but outputs the expanded mask
directly instead of computing a bounding box and overlay.

Algorithm (online, frame-by-frame with state):
  1. RGB -> Y luma extraction (same as motion.py)
  2. Frame 0: hard-init bg = Y_smooth; mask forced to zero.
     Frame N>0: selective EMA — motion pixels at slow rate, non-motion at
     fast rate (same as motion.py). EMA uses the RAW (pre-morph) mask so
     its behaviour matches the RTL (axis_motion_detect drives the EMA
     before axis_morph_clean runs downstream).
  3. Optional 3x3 morphological opening on the mask (display only).
  4. Mask-to-RGB expansion: mask=1 -> white, mask=0 -> black
"""

import numpy as np

from models.motion import (
    _rgb_to_y, _compute_mask, _ema_update, _selective_ema_update, _gauss3x3,
)
from models.ops.morph_open  import morph_open
from models.ops.morph_close import morph_close


def run(frames, motion_thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        grace_alpha_shift=1, gauss_en=True, morph_open_en=True,
        morph_close_en=False, morph_close_kernel=3, **kwargs):
    """Mask display reference model.

    Same motion detection front-end as motion.py (luma, frame-diff mask,
    selective EMA, frame-0 hard-init priming), but outputs the mask as
    black/white RGB instead of bbox overlay.

    Args:
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.
        motion_thresh: Motion threshold (default 16, matching RTL MOTION_THRESH).
        alpha_shift: Fast EMA shift (non-motion pixels, default 3, alpha=1/8).
        alpha_shift_slow: Slow EMA shift (motion pixels, default 6, alpha=1/64).
        grace_frames: Fast-EMA grace window after priming (default 0 = no grace).
        gauss_en: Enable 3x3 Gaussian pre-filter on Y channel (default True).
        morph_open_en: Apply 3x3 morphological opening to the mask (default True).
            Only affects the displayed mask; the EMA still updates from the
            raw (pre-morph) mask to match the RTL.
        morph_close_en: Apply morphological closing after open (default False).
        morph_close_kernel: Kernel size for closing (3 or 5, default 3).

    Returns:
        List of numpy arrays — the expected output frames (B/W only).
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]

    # Background buffer starts at zero (RAM is zero-initialized)
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    grace_cnt = 0

    outputs = []

    for frame in frames:
        # Step 1: RGB -> Y + optional Gaussian pre-filter
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur

        if not primed:
            # Frame 0: hard-init bg, mask forced to zero
            mask = np.zeros((h, w), dtype=bool)
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            # Frame N>0: grace window or selective EMA
            raw_mask = _compute_mask(y_cur_filt, y_bg, motion_thresh)
            # Optional morph opening for display / downstream only; EMA
            # always uses raw_mask to match the RTL (motion_detect drives
            # the EMA before morph_open runs).
            clean_mask = morph_open(raw_mask) if morph_open_en else raw_mask
            if morph_close_en:
                clean_mask = morph_close(clean_mask, kernel=morph_close_kernel)
            in_grace = grace_cnt < grace_frames
            # During grace, mask output is forced to 0 so the frame-0 ghost
            # region is not displayed; bg still converges at fast rate.
            mask = np.zeros_like(clean_mask) if in_grace else clean_mask
            if in_grace:
                y_bg = _ema_update(y_cur_filt, y_bg, grace_alpha_shift)
                grace_cnt += 1
            else:
                y_bg = _selective_ema_update(y_cur_filt, y_bg, raw_mask,
                                             alpha_shift, alpha_shift_slow)

        # Step 3: Expand 1-bit mask to 24-bit RGB
        out = np.zeros((h, w, 3), dtype=np.uint8)
        out[mask] = 255

        outputs.append(out)

    return outputs
