"""Triptych composition for the README demo: Input | CCL BBOX | MOTION."""

from typing import List
import numpy as np
from PIL import Image


def compose_triptych(
    input_frames:  List[np.ndarray],
    ccl_frames:    List[np.ndarray],
    motion_frames: List[np.ndarray],
) -> List[Image.Image]:
    """Build per-frame side-by-side triptychs (Input | CCL BBOX | MOTION).

    All three input streams must be RGB888 ndarrays with identical shape
    (H, W, 3) and identical frame counts. Output frames are PIL RGB Images of
    size (3*W, H). Panels abut directly. The on-output HUD already labels
    each panel with its ctrl-flow tag, so no separate panel labels are drawn.
    """
    n = len(input_frames)
    assert len(ccl_frames) == n and len(motion_frames) == n, \
        f"frame count mismatch: input={n} ccl={len(ccl_frames)} motion={len(motion_frames)}"
    assert n > 0, "at least one frame required"

    h, w, _ = input_frames[0].shape
    for f in input_frames + ccl_frames + motion_frames:
        assert f.shape == (h, w, 3), f"shape mismatch: expected ({h}, {w}, 3), got {f.shape}"
        assert f.dtype == np.uint8, f"dtype must be uint8, got {f.dtype}"

    out: List[Image.Image] = []
    for i in range(n):
        canvas = np.zeros((h, 3 * w, 3), dtype=np.uint8)
        canvas[:, 0:w]     = input_frames[i]
        canvas[:, w:2*w]   = ccl_frames[i]
        canvas[:, 2*w:3*w] = motion_frames[i]
        out.append(Image.fromarray(canvas, mode="RGB"))
    return out
