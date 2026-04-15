"""Motion detection control flow reference model.

Implements the full motion pipeline from the algorithm specification:
  1. RGB -> Y luma extraction (Rec.601-ish, 8-bit fixed-point)
  2. Frame-difference motion mask (|Y_cur - Y_prev| > threshold)
  3. Bounding box reduction with priming suppression
  4. Rectangle overlay with 1-frame delay

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


def _rgb_to_y(frame):
    """Extract luma using project fixed-point coefficients.

    Y = (77*R + 150*G + 29*B) >> 8, truncated to uint8.
    """
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    y_sum = _Y_R * r + _Y_G * g + _Y_B * b
    return (y_sum >> 8).astype(np.uint8)


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


def run(frames, thresh=16, **kwargs):
    """Motion pipeline reference model.

    Processes frames online with state, matching the streaming RTL behavior.

    Args:
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.
        thresh: Motion threshold (default 16, matching RTL MOTION_THRESH).

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

        # Step 2: Motion mask
        mask = _compute_mask(y_cur, y_ref, thresh)

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

        # Step 6: Update reference buffer (raw write-back)
        y_ref = y_cur.copy()

        outputs.append(out)

    return outputs
