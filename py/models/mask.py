"""Mask display control flow reference model.

Displays the raw 1-bit motion mask as a black-and-white image.
Reuses the motion pipeline's luma extraction and frame-difference mask
logic, but outputs the expanded mask directly instead of computing a
bounding box and overlay.

Algorithm (online, frame-by-frame with state):
  1. RGB -> Y luma extraction (same as motion.py)
  2. Frame-difference motion mask (same as motion.py)
  3. Mask-to-RGB expansion: mask=1 -> white, mask=0 -> black
  4. Update reference buffer via EMA (same as motion.py)
"""

import numpy as np

from models.motion import _rgb_to_y, _compute_mask, _ema_update, _gauss3x3


def run(frames, thresh=16, alpha_shift=3, gauss_en=True, **kwargs):
    """Mask display reference model.

    Same motion detection front-end as motion.py (luma, frame-diff mask),
    but outputs the raw mask as black/white RGB instead of bbox overlay.

    Args:
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.
        thresh: Motion threshold (default 16, matching RTL MOTION_THRESH).
        alpha_shift: EMA smoothing factor (default 3, alpha=1/8).
        gauss_en: Enable 3x3 Gaussian pre-filter on Y channel (default True).

    Returns:
        List of numpy arrays — the expected output frames (B/W only).
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]

    # Y-prev buffer starts at zero (RAM is zero-initialized)
    y_ref = np.zeros((h, w), dtype=np.uint8)

    outputs = []

    for frame in frames:
        # Step 1: RGB -> Y
        y_cur = _rgb_to_y(frame)

        # Step 1b: Optional Gaussian pre-filter
        if gauss_en:
            y_cur_filt = _gauss3x3(y_cur)
        else:
            y_cur_filt = y_cur

        # Step 2: Motion mask (uses filtered Y)
        mask = _compute_mask(y_cur_filt, y_ref, thresh)

        # Step 3: Expand 1-bit mask to 24-bit RGB
        out = np.zeros((h, w, 3), dtype=np.uint8)
        out[mask] = 255

        # Step 4: Update reference buffer (EMA write-back, uses filtered Y)
        y_ref = _ema_update(y_cur_filt, y_ref, alpha_shift)

        outputs.append(out)

    return outputs
