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

from models.ccl import run_ccl

# Project-specific coefficients from rgb2ycrcb.sv:
#   y_sum_c = 77*R + 150*G + 29*B;  output = y_sum_c[15:8]
_Y_R = 77
_Y_G = 150
_Y_B = 29

BBOX_COLOR = np.array([0x00, 0xFF, 0x00], dtype=np.uint8)
PRIME_FRAMES = 2


def _gauss3x3(y_frame):
    """True centered 3x3 Gaussian blur.

    Kernel: [1 2 1; 2 4 2; 1 2 1] / 16. For output pixel (r, c) the kernel
    is centered at (r, c). Edge replication (np.pad mode='edge') handles
    border pixels, matching the RTL's clamp-at-edge behavior.

    Integer arithmetic with >>4 truncation, not floating-point.
    """
    h, w = y_frame.shape
    padded = np.pad(y_frame, 1, mode='edge')

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


# CCL defaults — mirror the RTL parameters. Keep in sync with sparevideo_pkg.
N_OUT                = 8
N_LABELS_INT         = 64
MIN_COMPONENT_PIXELS = 16
MAX_CHAIN_DEPTH      = 8


def _draw_bboxes(frame, bboxes):
    """Draw 1-pixel-thick rectangles for each non-None bbox. Returns a modified copy.

    Assumes bboxes are in-range. run_ccl produces coords strictly within the frame.
    """
    out = frame.copy()
    for b in bboxes:
        if b is None:
            continue
        min_x, max_x, min_y, max_y, _count = b
        for y in range(min_y, max_y + 1):
            out[y, min_x] = BBOX_COLOR
            out[y, max_x] = BBOX_COLOR
        for x in range(min_x, max_x + 1):
            out[min_y, x] = BBOX_COLOR
            out[max_y, x] = BBOX_COLOR
    return out


def _selective_ema_update(y_cur, bg_prev, mask, alpha_shift, alpha_shift_slow):
    """Two-rate EMA update (bit-exact with RTL).

    Motion pixels update at the slow rate, non-motion at the fast rate.
    Both rates share one subtraction; two arithmetic right-shifts; uint8 wrap.
    """
    delta = y_cur.astype(np.int16) - bg_prev.astype(np.int16)
    step_fast = delta >> alpha_shift        # numpy >> is arithmetic for signed
    step_slow = delta >> alpha_shift_slow
    step = np.where(mask, step_slow, step_fast)
    new_bg = bg_prev.astype(np.int16) + step
    return np.clip(new_bg, 0, 255).astype(np.uint8)


def _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                  gauss_en=True):
    """Run the motion model's bg trajectory for inspection. Returns a list of
    bg arrays — one per frame, representing the RAM state after that frame is
    processed. Does not produce visual output.
    """
    if not frames:
        return []
    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    trace = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur
        if not primed:
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                          alpha_shift, alpha_shift_slow)
        trace.append(y_bg.copy())
    return trace


def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, gauss_en=True,
        **kwargs):
    """Motion pipeline reference model (CCL-based, multi-bbox).

    Frame 0: priming — bg[px] = Y_smooth(frame_0[px]), mask forced to 0.
    Frame N>0: selective EMA — motion pixels drift at slow rate, non-motion at
    fast rate.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    bboxes_state = [None] * N_OUT

    outputs = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur

        if not primed:
            # Frame 0 — hard-init bg, mask forced to zero
            mask = np.zeros((h, w), dtype=bool)
            out = _draw_bboxes(frame, bboxes_state)  # bboxes_state all-None
            new_bboxes = run_ccl(
                [mask],
                n_out=N_OUT,
                n_labels_int=N_LABELS_INT,
                min_component_pixels=MIN_COMPONENT_PIXELS,
                max_chain_depth=MAX_CHAIN_DEPTH,
            )[0]
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            out = _draw_bboxes(frame, bboxes_state)
            new_bboxes = run_ccl(
                [mask],
                n_out=N_OUT,
                n_labels_int=N_LABELS_INT,
                min_component_pixels=MIN_COMPONENT_PIXELS,
                max_chain_depth=MAX_CHAIN_DEPTH,
            )[0]
            y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                          alpha_shift, alpha_shift_slow)

        # Bbox priming suppression (unchanged)
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT

        outputs.append(out)

    return outputs
