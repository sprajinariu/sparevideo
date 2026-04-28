"""2x bilinear spatial upscaler reference model. Mirrors axis_scale2x RTL.

Arithmetic-mean horizontal and vertical interpolation, top-edge row
replication, right-edge pixel replication. All averages are integer
(a+b+1)>>1 to match the RTL bit-exactly. The 2x2 corner is built as
two avg2's of avg2's (sequential 2-tap), matching the RTL.
"""
from __future__ import annotations

import numpy as np


def _avg2(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return ((a.astype(np.uint16) + b.astype(np.uint16) + 1) >> 1).astype(np.uint8)


def scale2x(image: np.ndarray) -> np.ndarray:
    """Return a 2x bilinear-upscaled copy of `image`.

    Args:
        image: (H, W, 3) uint8 RGB.

    Returns:
        (2H, 2W, 3) uint8 RGB. Input is not mutated.
    """
    if image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
        raise ValueError(f"scale2x expects (H,W,3) uint8; got {image.shape} {image.dtype}")

    h, w, c = image.shape
    out = np.zeros((2 * h, 2 * w, c), dtype=np.uint8)

    # Horizontal expansion: each source row -> 2W out: A, (A+B)/2, B, (B+C)/2, …, X, X
    even = image
    odd  = np.empty_like(image)
    odd[:, :-1, :] = _avg2(image[:, :-1, :], image[:, 1:, :])
    odd[:, -1,  :] = image[:, -1, :]                   # right-edge replicate

    horiz = np.empty((h, 2 * w, c), dtype=np.uint8)
    horiz[:, 0::2, :] = even
    horiz[:, 1::2, :] = odd

    # Vertical expansion: top output row of pair == source row;
    # bottom output row == avg of source row and previous source row
    # (top-edge replicate: row 0's "previous" is row 0).
    top = horiz
    prev = np.concatenate([horiz[:1, :, :], horiz[:-1, :, :]], axis=0)
    bot = _avg2(top, prev)

    out[0::2, :, :] = top
    out[1::2, :, :] = bot
    return out
