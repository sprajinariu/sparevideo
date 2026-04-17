"""Motion detection control flow reference model.

Implements the full motion pipeline from the algorithm specification:
  1. RGB -> Y luma extraction (Rec.601-ish, 8-bit fixed-point)
  2. Frame-difference motion mask (|Y_cur - Y_ref| > threshold)
  3. EMA background model update: bg_new = bg + (Y_cur - bg) >> alpha_shift
  4. Bounding box reduction with priming suppression
  5. Rectangle overlay with 1-frame delay

This is a spec-driven model, not an RTL transcription. It implements the
intended algorithmic behavior. If the RTL disagrees with this model, the
RTL is wrong.
"""

import numpy as np


# Project-specific coefficients from rgb2ycrcb.sv:
#   y_sum_c = 77*R + 150*G + 29*B;  output = y_sum_c[15:8]
_Y_R = 77
_Y_G = 150
_Y_B = 29

BBOX_COLOR = np.array([0x00, 0xFF, 0x00], dtype=np.uint8)
PRIME_FRAMES = 2


def _gauss3x3(y_frame):
    """3x3 Gaussian blur matching RTL causal streaming filter.

    Kernel: [1 2 1; 2 4 2; 1 2 1] / 16.

    The RTL uses a causal streaming architecture (2-deep line buffers +
    2-deep column shift registers) that centers the convolution at (r-1, c-1)
    relative to scan position (r, c). To match this, the model computes
    a standard centered convolution, then shifts the result by (-1, -1) —
    i.e., for output pixel (r, c), the Gaussian is centered at (r-1, c-1).
    Edge replication (np.pad mode='edge') handles border pixels, matching
    the RTL's clamp-at-edge behavior.

    Integer arithmetic with >>4 truncation, not floating-point.
    """
    h, w = y_frame.shape

    # Pad by 2 on each side: 1 for the kernel radius, 1 for the causal offset.
    # After convolution on the padded array, the causal-offset output for pixel
    # (r, c) is at padded position (r, c) — i.e., kernel centered at (r-1, c-1)
    # in the original image coordinates.
    padded = np.pad(y_frame, 2, mode='edge')

    # Convolution centered at (r-1, c-1) for each output pixel (r, c):
    # padded[r-1+dr, c-1+dc] with dr,dc in {0,1,2} → padded[r+1+dr, c+1+dc]
    # after accounting for the pad=2 offset.
    # But since we want center=(r-1,c-1), that's padded index (r-1+2, c-1+2)
    # for the center, so the 3x3 window starts at padded[r, c].
    result = np.zeros((h, w), dtype=np.uint16)
    for dr in range(3):
        for dc in range(3):
            weight = [1, 2, 1][dr] * [1, 2, 1][dc]
            result += weight * padded[dr:dr+h, dc:dc+w].astype(np.uint16)

    return (result >> 4).astype(np.uint8)


def _rgb_to_y(frame):
    """Extract luma using project fixed-point coefficients.

    Y = (77*R + 150*G + 29*B) >> 8, truncated to uint8.
    """
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    y_sum = _Y_R * r + _Y_G * g + _Y_B * b
    return (y_sum >> 8).astype(np.uint8)


def _ema_update(y_cur, bg_prev, alpha_shift=3):
    """EMA background update matching RTL arithmetic.

    bg_new = bg_prev + (y_cur - bg_prev) >> alpha_shift
    Uses arithmetic right-shift (sign-preserving) and uint8 truncation.
    When alpha_shift=0, reduces to raw write-back (bg_new = y_cur).
    """
    delta = y_cur.astype(np.int16) - bg_prev.astype(np.int16)
    step = delta >> alpha_shift  # numpy >> is arithmetic for signed types
    new_bg = bg_prev.astype(np.int16) + step
    return np.clip(new_bg, 0, 255).astype(np.uint8)


def _compute_mask(y_cur, y_ref, thresh):
    """Compute motion mask: |Y_cur - Y_ref| > thresh (strict >)."""
    diff = np.abs(y_cur.astype(np.int16) - y_ref.astype(np.int16))
    return diff > thresh


def _compute_bbox(mask):
    """Compute tightest bounding box of motion pixels.

    Returns (min_x, max_x, min_y, max_y, empty).
    """
    motion_pixels = np.argwhere(mask)
    if len(motion_pixels) == 0:
        return 0, 0, 0, 0, True
    min_y = int(motion_pixels[:, 0].min())
    max_y = int(motion_pixels[:, 0].max())
    min_x = int(motion_pixels[:, 1].min())
    max_x = int(motion_pixels[:, 1].max())
    return min_x, max_x, min_y, max_y, False


def _draw_bbox(frame, min_x, max_x, min_y, max_y, empty):
    """Draw 1-pixel rectangle border on frame. Returns modified copy."""
    out = frame.copy()
    if empty:
        return out

    h, w = frame.shape[:2]

    # Left and right vertical edges (within y range)
    for y in range(min_y, max_y + 1):
        if 0 <= min_x < w:
            out[y, min_x] = BBOX_COLOR
        if 0 <= max_x < w:
            out[y, max_x] = BBOX_COLOR

    # Top and bottom horizontal edges (within x range)
    for x in range(min_x, max_x + 1):
        if 0 <= min_y < h:
            out[min_y, x] = BBOX_COLOR
        if 0 <= max_y < h:
            out[max_y, x] = BBOX_COLOR

    return out


def run(frames, thresh=16, alpha_shift=3, gauss_en=True, **kwargs):
    """Motion pipeline reference model.

    Processes frames online with state, matching the streaming RTL behavior.

    Args:
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.
        thresh: Motion threshold (default 16, matching RTL MOTION_THRESH).
        alpha_shift: EMA smoothing factor (default 3, alpha=1/8).
        gauss_en: Enable 3x3 Gaussian pre-filter on Y channel (default True).

    Returns:
        List of numpy arrays — the expected output frames.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]

    # Y-prev buffer starts at zero (RAM is zero-initialized)
    y_ref = np.zeros((h, w), dtype=np.uint8)

    # Bbox state: starts empty (bbox_empty=1 after reset)
    bbox_state = (0, 0, 0, 0, True)  # (min_x, max_x, min_y, max_y, empty)

    # Frame counter for priming suppression
    frame_cnt = 0

    outputs = []

    for i, frame in enumerate(frames):
        # Step 1: RGB -> Y
        y_cur = _rgb_to_y(frame)

        # Step 1b: Optional Gaussian pre-filter
        if gauss_en:
            y_cur_filt = _gauss3x3(y_cur)
        else:
            y_cur_filt = y_cur

        # Step 2: Motion mask (uses filtered Y)
        mask = _compute_mask(y_cur_filt, y_ref, thresh)

        # Step 3: Overlay bbox from PREVIOUS frame onto current frame
        # (1-frame delay: bbox is computed at EOF of frame N, applied to frame N+1)
        out = _draw_bbox(frame, *bbox_state)

        # Step 4: Compute this frame's bbox (will be used for NEXT frame's overlay)
        new_bbox = _compute_bbox(mask)

        # Step 5: Priming suppression (PrimeFrames=2)
        # bbox_reduce: primed = (frame_cnt == PrimeFrames)
        # frame_cnt increments on is_eof_r when !primed.
        # Due to NBA semantics, latch reads OLD frame_cnt, so:
        #   frame 0 EOF: frame_cnt=0, primed=false -> empty. Then frame_cnt becomes 1.
        #   frame 1 EOF: frame_cnt=1, primed=false -> empty. Then frame_cnt becomes 2.
        #   frame 2 EOF: frame_cnt=2, primed=true  -> valid bbox.
        primed = (frame_cnt == PRIME_FRAMES)
        if not primed or new_bbox[4]:  # not primed OR no motion
            bbox_state = (0, 0, 0, 0, True)
        else:
            bbox_state = new_bbox

        # Advance priming counter (after latch decision, matching NBA timing)
        if not primed:
            frame_cnt += 1

        # Step 6: Update reference buffer (EMA write-back, uses filtered Y)
        y_ref = _ema_update(y_cur_filt, y_ref, alpha_shift)

        outputs.append(out)

    return outputs
